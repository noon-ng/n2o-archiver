#import "NA7zzTool.h"

static NSString *const NA7zzErrorDomain = @"sh.n2o.archiver.7zz";

@implementation NA7zzProgressParser {
    NSMutableData *_buffer;
    NSString *_lastEntry;
    void (^_handler)(double, NSString *);
}

- (instancetype)initWithHandler:(void (^)(double, NSString *))handler {
    self = [super init];
    if (self) {
        _buffer = [NSMutableData data];
        _lastEntry = @"";
        _handler = [handler copy];
    }
    return self;
}

- (void)appendData:(NSData *)data {
    @synchronized (self) {
        [_buffer appendData:data];

        // Process every segment that ends in a backspace or newline; keep the
        // unterminated remainder for the next call.
        const uint8_t *bytes = _buffer.bytes;
        NSUInteger length = _buffer.length;
        NSUInteger start = 0;
        for (NSUInteger i = 0; i < length; i++) {
            if (bytes[i] == '\b' || bytes[i] == '\n' || bytes[i] == '\r') {
                if (i > start) {
                    [self processSegment:[_buffer subdataWithRange:
                        NSMakeRange(start, i - start)]];
                }
                start = i + 1;
            }
        }
        [_buffer replaceBytesInRange:NSMakeRange(0, start) withBytes:NULL length:0];
    }
}

- (void)processSegment:(NSData *)segment {
    NSString *text = [[NSString alloc] initWithData:segment encoding:NSUTF8StringEncoding]
                  ?: [[NSString alloc] initWithData:segment encoding:NSISOLatin1StringEncoding];

    // "NN%", optionally followed by a file count and "- path".
    static NSRegularExpression *pattern;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        pattern = [NSRegularExpression
            regularExpressionWithPattern:@"^\\s*(\\d{1,3})%(?:\\s+\\d+)?(?:\\s+-\\s+(.*\\S))?\\s*$"
                                 options:0
                                   error:nil];
    });

    NSTextCheckingResult *match =
        [pattern firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    if (!match) return;

    double fraction = [[text substringWithRange:[match rangeAtIndex:1]] doubleValue] / 100.0;
    if (fraction > 1.0) fraction = 1.0;

    NSRange nameRange = [match rangeAtIndex:2];
    if (nameRange.location != NSNotFound) {
        _lastEntry = [text substringWithRange:nameRange].lastPathComponent;
    }
    _handler(fraction, _lastEntry);
}

@end

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

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:tool];
    // -bsp1 sends progress to stdout even when stdout is not a terminal.
    task.arguments = @[@"x", @"-y", @"-bsp1",
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

    // stdout is always read, so 7zz cannot block on a full pipe. The handler
    // runs on a file handle queue, not the calling thread.
    __block NSString *lastEntry = @"";
    NA7zzProgressParser *parser =
        [[NA7zzProgressParser alloc] initWithHandler:^(double fraction, NSString *entry) {
        lastEntry = entry;
        if (progressBlock) progressBlock(fraction, entry);
    }];
    NSFileHandle *outHandle = outPipe.fileHandleForReading;
    outHandle.readabilityHandler = ^(NSFileHandle *fh) {
        [parser appendData:[fh availableData]];
    };

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
    [parser appendData:[outHandle readDataToEndOfFile]];

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

    if (progressBlock) {
        // The parser calls its handler while holding its own lock.
        NSString *entry;
        @synchronized (parser) { entry = lastEntry; }
        progressBlock(1.0, entry);
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

@end
