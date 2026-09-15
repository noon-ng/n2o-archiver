#import <Foundation/Foundation.h>
#import "NAExtractorPlugin.h"

NS_ASSUME_NONNULL_BEGIN

/// Parses the progress output of `7zz x -bsp1`. 7zz writes status strings
/// such as " 45% 3 - dir/file.txt" and overwrites them with runs of backspaces;
/// the handler receives the percentage as a fraction and the file name.
/// appendData: may be called from any thread, with data split at any byte.
@interface NA7zzProgressParser : NSObject

- (instancetype)initWithHandler:(void (^)(double fraction, NSString *entry))handler;
- (void)appendData:(NSData *)data;

@end

@interface NA7zzTool : NSObject

+ (nullable NSString *)toolPath;

/// formatType is passed to 7zz as -t<formatType> (for example @"7z", @"rar",
/// @"rar5"), so the archive is opened only as that format. isCancelled is
/// polled while 7zz runs; when it returns YES the task is terminated and the
/// call returns NO with NSUserCancelledError.
+ (BOOL)extractArchiveAtPath:(NSString *)archivePath
                  formatType:(NSString *)formatType
               toDestination:(NSString *)destPath
                    progress:(nullable NAExtractionProgressBlock)progressBlock
                 isCancelled:(nullable BOOL (^)(void))isCancelled
                       error:(NSError **)error;

+ (nullable NSArray<NSString *> *)contentsOfArchiveAtPath:(NSString *)path
                                               formatType:(NSString *)formatType
                                                    error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
