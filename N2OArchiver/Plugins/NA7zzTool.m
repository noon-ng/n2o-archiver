#import "NA7zzTool.h"

static NSString *const NA7zzErrorDomain = @"sh.n2o.archiver.7zz";

@implementation NA7zzTool

+ (nullable NSString *)toolPath {
    static NSString *path;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSString *> *candidates = @[
            @"/opt/homebrew/bin/7zz",
            @"/usr/local/bin/7zz",
            @"/opt/homebrew/bin/7z",
            @"/usr/local/bin/7z",
        ];
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *p in candidates) {
            if ([fm isExecutableFileAtPath:p]) {
                path = p;
                return;
            }
        }
    });
    return path;
}

+ (BOOL)extractArchiveAtPath:(NSString *)archivePath
               toDestination:(NSString *)destPath
                    progress:(nullable NAExtractionProgressBlock)progressBlock
                 isCancelled:(nullable BOOL (^)(void))isCancelled
                       error:(NSError **)error {
    if (isCancelled && isCancelled()) {
        [self setCancelledError:error];
        return NO;
    }

    NSString *tool = [self toolPath];
    if (!tool) {
        if (error) {
            *error = [NSError errorWithDomain:NA7zzErrorDomain
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         @"7zz not found"}];
        }
        return NO;
    }

    int64_t totalSize = [self totalUncompressedSize:archivePath];

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:tool];
    task.arguments = @[@"x", @"-y",
                       [NSString stringWithFormat:@"-o%@", destPath],
                       archivePath];

    NSPipe *outPipe = [NSPipe pipe];
    NSPipe *errPipe = [NSPipe pipe];
    task.standardOutput = outPipe;
    task.standardError = errPipe;

    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        if (error) *error = launchError;
        return NO;
    }

    NSFileHandle *outHandle = outPipe.fileHandleForReading;
    __block int64_t extractedSize = 0;

    if (progressBlock && totalSize > 0) {
        outHandle.readabilityHandler = ^(NSFileHandle *fh) {
            NSData *data = [fh availableData];
            if (data.length == 0) return;

            NSString *chunk = [[NSString alloc] initWithData:data
                                                    encoding:NSUTF8StringEncoding];
            if (!chunk) return;

            for (NSString *line in [chunk componentsSeparatedByString:@"\n"]) {
                NSString *trimmed = [line stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if ([trimmed hasPrefix:@"- "]) {
                    NSString *name = [trimmed substringFromIndex:2];
                    progressBlock((double)extractedSize / (double)totalSize,
                                  name.lastPathComponent);
                }
            }
        };
    }

    // Poll for cancellation while 7zz runs.
    BOOL cancelled = NO;
    while (task.isRunning) {
        if (isCancelled && isCancelled()) {
            cancelled = YES;
            [task terminate];
            break;
        }
        [NSThread sleepForTimeInterval:0.05];
    }
    [task waitUntilExit];
    outHandle.readabilityHandler = nil;

    // The cancel may arrive after 7zz has exited; report it so the caller
    // treats the output as cancelled.
    if (cancelled || (isCancelled && isCancelled())) {
        [self setCancelledError:error];
        return NO;
    }

    if (task.terminationStatus != 0) {
        NSData *errData = [errPipe.fileHandleForReading readDataToEndOfFile];
        NSString *errMsg = [[NSString alloc] initWithData:errData
                                                 encoding:NSUTF8StringEncoding]
                           ?: @"7zz extraction failed";
        if (error) {
            *error = [NSError errorWithDomain:NA7zzErrorDomain
                                         code:task.terminationStatus
                                     userInfo:@{NSLocalizedDescriptionKey: errMsg}];
        }
        return NO;
    }

    return YES;
}

+ (nullable NSArray<NSString *> *)contentsOfArchiveAtPath:(NSString *)path
                                                    error:(NSError **)error {
    NSString *tool = [self toolPath];
    if (!tool) {
        if (error) {
            *error = [NSError errorWithDomain:NA7zzErrorDomain
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         @"7zz not found"}];
        }
        return nil;
    }

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:tool];
    task.arguments = @[@"l", @"-slt", path];

    NSPipe *outPipe = [NSPipe pipe];
    task.standardOutput = outPipe;
    task.standardError = [NSPipe pipe];

    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        if (error) *error = launchError;
        return nil;
    }

    NSData *outData = [outPipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];

    NSString *output = [[NSString alloc] initWithData:outData
                                             encoding:NSUTF8StringEncoding];
    if (!output) return @[];

    NSMutableArray<NSString *> *entries = [NSMutableArray array];
    for (NSString *line in [output componentsSeparatedByString:@"\n"]) {
        if ([line hasPrefix:@"Path = "]) {
            NSString *entry = [line substringFromIndex:7];
            if (entry.length > 0 && ![entry isEqualToString:path.lastPathComponent]) {
                [entries addObject:entry];
            }
        }
    }

    return entries;
}

#pragma mark - Private

+ (void)setCancelledError:(NSError **)error {
    if (!error) return;
    *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                 code:NSUserCancelledError
                             userInfo:nil];
}

+ (int64_t)totalUncompressedSize:(NSString *)archivePath {
    NSString *tool = [self toolPath];
    if (!tool) return -1;

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:tool];
    task.arguments = @[@"l", @"-slt", archivePath];

    NSPipe *outPipe = [NSPipe pipe];
    task.standardOutput = outPipe;
    task.standardError = [NSPipe pipe];

    if (![task launchAndReturnError:nil]) return -1;

    NSData *outData = [outPipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];

    NSString *output = [[NSString alloc] initWithData:outData
                                             encoding:NSUTF8StringEncoding];
    if (!output) return -1;

    int64_t total = 0;
    for (NSString *line in [output componentsSeparatedByString:@"\n"]) {
        if ([line hasPrefix:@"Size = "]) {
            NSString *sizeStr = [line substringFromIndex:7];
            long long val = [sizeStr longLongValue];
            if (val > 0) total += val;
        }
    }
    return total;
}

@end
