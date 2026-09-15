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

    __block NSString *lastEntry = @"";
    NA7zzProgressParser *parser =
        [[NA7zzProgressParser alloc] initWithHandler:^(double fraction, NSString *entry) {
        lastEntry = entry;
        if (progressBlock) progressBlock(fraction, entry);
    }];

    // -bsp1 sends progress to stdout even when stdout is not a terminal.
    NSArray<NSString *> *arguments = @[
        // "-p" with no value supplies an empty password, so an encrypted
        // archive fails instead of prompting.
        @"x", @"-y", @"-bsp1", @"-p",
        [NSString stringWithFormat:@"-o%@", destPath],
        @"--", archivePath
    ];

    BOOL cancelled = NO;
    NSData *stderrData = nil;
    int status = [self runWithArguments:arguments
                          stdoutHandler:^(NSData *data) { [parser appendData:data]; }
                            isCancelled:isCancelled
                              cancelled:&cancelled
                             stderrData:&stderrData
                                  error:error];
    if (status < 0) return NO;

    // The cancel may arrive after 7zz has exited; report it so the caller
    // treats the output as cancelled.
    if (cancelled || (isCancelled && isCancelled())) {
        [self setCancelledError:error];
        return NO;
    }

    if (status != 0) {
        if (error) *error = [self errorForStatus:status stderrData:stderrData
                                        fallback:@"7zz could not extract the archive."];
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
    NSMutableData *output = [NSMutableData data];
    NSData *stderrData = nil;
    int status = [self runWithArguments:@[@"l", @"-slt", @"-p", @"--", path]
                          stdoutHandler:^(NSData *data) { [output appendData:data]; }
                            isCancelled:nil
                              cancelled:NULL
                             stderrData:&stderrData
                                  error:error];
    if (status < 0) return nil;
    if (status != 0) {
        if (error) *error = [self errorForStatus:status stderrData:stderrData
                                        fallback:@"7zz could not list the archive."];
        return nil;
    }

    NSString *text = [[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding];
    if (!text) return @[];

    // `l -slt` prints a block describing the archive itself (including its own
    // "Path = " line), then a "----------" line, then one block per member.
    NSMutableArray<NSString *> *entries = [NSMutableArray array];
    BOOL inMembers = NO;
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if (!inMembers) {
            if ([line hasPrefix:@"----------"]) inMembers = YES;
            continue;
        }
        if ([line hasPrefix:@"Path = "]) {
            NSString *entry = [line substringFromIndex:7];
            if (entry.length > 0) [entries addObject:entry];
        }
    }
    return entries;
}

#pragma mark - Private

// Runs 7zz with stdin on /dev/null, so a prompt reads end-of-file instead of
// waiting; callers also pass "-p" so no prompt is shown. stdout is passed to
// stdoutHandler as it arrives and stderr is collected, both while the process
// runs, so neither pipe can fill. Polls isCancelled every 50 ms and terminates 7zz when it
// returns YES. Returns the exit status, or -1 if 7zz could not be started.
+ (int)runWithArguments:(NSArray<NSString *> *)arguments
          stdoutHandler:(void (^)(NSData *data))stdoutHandler
            isCancelled:(nullable BOOL (^)(void))isCancelled
              cancelled:(nullable BOOL *)cancelled
             stderrData:(NSData **)stderrData
                  error:(NSError **)error {
    NSString *tool = [self toolPath];
    if (!tool) {
        if (error) {
            *error = [NSError errorWithDomain:NA7zzErrorDomain
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         @"7zz not found"}];
        }
        return -1;
    }

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:tool];
    task.arguments = arguments;
    task.standardInput = [NSFileHandle fileHandleWithNullDevice];

    NSPipe *outPipe = [NSPipe pipe];
    NSPipe *errPipe = [NSPipe pipe];
    task.standardOutput = outPipe;
    task.standardError = errPipe;

    NSMutableData *errData = [NSMutableData data];
    NSFileHandle *outHandle = outPipe.fileHandleForReading;
    NSFileHandle *errHandle = errPipe.fileHandleForReading;
    // The handlers run on file handle queues, not the calling thread.
    outHandle.readabilityHandler = ^(NSFileHandle *fh) {
        NSData *data = [fh availableData];
        if (data.length > 0) stdoutHandler(data);
    };
    errHandle.readabilityHandler = ^(NSFileHandle *fh) {
        NSData *data = [fh availableData];
        if (data.length > 0) {
            @synchronized (errData) { [errData appendData:data]; }
        }
    };

    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        outHandle.readabilityHandler = nil;
        errHandle.readabilityHandler = nil;
        if (error) *error = launchError;
        return -1;
    }

    BOOL didCancel = NO;
    while (task.isRunning) {
        if (isCancelled && isCancelled()) {
            didCancel = YES;
            [task terminate];
            break;
        }
        [NSThread sleepForTimeInterval:0.05];
    }
    [task waitUntilExit];

    outHandle.readabilityHandler = nil;
    errHandle.readabilityHandler = nil;
    NSData *outRest = [outHandle readDataToEndOfFile];
    if (outRest.length > 0) stdoutHandler(outRest);
    NSData *errRest = [errHandle readDataToEndOfFile];

    if (cancelled) *cancelled = didCancel;
    if (stderrData) {
        @synchronized (errData) {
            [errData appendData:errRest];
            *stderrData = [errData copy];
        }
    }
    return task.terminationStatus;
}

+ (NSError *)errorForStatus:(int)status
                 stderrData:(NSData *)stderrData
                   fallback:(NSString *)fallback {
    NSString *text = [[[NSString alloc] initWithData:stderrData encoding:NSUTF8StringEncoding]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    // The description is a short summary; 7zz's own output is the failure
    // reason. With an empty "-p", 7zz reports encrypted content as a wrong
    // password.
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    if ([text containsString:@"Wrong password"]) {
        userInfo[NSLocalizedDescriptionKey] = @"The archive is password-protected.";
        userInfo[NSLocalizedRecoverySuggestionErrorKey] =
            @"N2O Archiver cannot extract password-protected archives yet.";
    } else {
        userInfo[NSLocalizedDescriptionKey] = fallback;
    }
    if (text.length > 0) userInfo[NSLocalizedFailureReasonErrorKey] = text;
    return [NSError errorWithDomain:NA7zzErrorDomain code:status userInfo:userInfo];
}


+ (void)setCancelledError:(NSError **)error {
    if (!error) return;
    *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                 code:NSUserCancelledError
                             userInfo:nil];
}

@end
