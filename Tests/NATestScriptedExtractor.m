#import "NATestScriptedExtractor.h"
#include <sys/stat.h>

dispatch_semaphore_t NAScriptedRelease;

@implementation NATestScriptedExtractor

+ (NSArray<NSString *> *)supportedExtensions { return @[@"n2oscripted"]; }
+ (NSArray<NSString *> *)supportedUTIs { return @[]; }
+ (BOOL)canHandleFileAtPath:(NSString *)path {
    return [path.pathExtension isEqualToString:@"n2oscripted"];
}

static NSError *NAScriptedError(NSInteger code, NSDictionary *userInfo) {
    return [NSError errorWithDomain:@"NATestScriptedExtractor" code:code userInfo:userInfo];
}

- (BOOL)extractArchiveAtPath:(NSString *)archivePath
               toDestination:(NSString *)destPath
                    progress:(NSProgress *)progress
                       error:(NSError **)error {
    NSString *file = [destPath stringByAppendingPathComponent:@"payload.txt"];
    [@"payload" writeToFile:file atomically:NO encoding:NSUTF8StringEncoding error:nil];
    NSString *name = archivePath.lastPathComponent;

    if ([name hasPrefix:@"wait"]) {
        progress.totalUnitCount = 2;
        progress.fileURL = [NSURL fileURLWithPath:file];
        progress.completedUnitCount = 1;
        for (int i = 0; i < 1000; i++) {
            if (dispatch_semaphore_wait(NAScriptedRelease,
                                        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_MSEC))) == 0) {
                progress.completedUnitCount = 2;
                return YES;
            }
            if (progress.isCancelled) {
                if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil];
                return NO;
            }
        }
        return YES;
    }
    if ([name hasPrefix:@"cancel-fail"]) {
        dispatch_semaphore_wait(NAScriptedRelease,
                                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)));
        if (error) *error = NAScriptedError(4, @{NSLocalizedDescriptionKey: @"Failed while cancelling."});
        return NO;
    }
    if ([name hasPrefix:@"fail"]) {
        if (error) *error = NAScriptedError(2, @{NSLocalizedDescriptionKey: @"Unsupported compression method."});
        return NO;
    }
    if ([name hasPrefix:@"immutable"]) {
        chflags(file.fileSystemRepresentation, UF_IMMUTABLE);
        if (error) *error = NAScriptedError(1, @{NSLocalizedDescriptionKey: @"Scripted extraction failure."});
        return NO;
    }
    if ([name hasPrefix:@"long-error"]) {
        NSMutableString *output = [NSMutableString string];
        for (int i = 1; i <= 500; i++) {
            [output appendFormat:@"ERROR: Unsupported Method : folder/file-%d.bin\n", i];
        }
        if (error) {
            *error = NAScriptedError(3, @{NSLocalizedDescriptionKey: @"7zz could not extract the archive.",
                                          NSLocalizedFailureReasonErrorKey: output});
        }
        return NO;
    }
    return YES;
}

@end
