#import <Foundation/Foundation.h>
#import "NAExtractorPlugin.h"

NS_ASSUME_NONNULL_BEGIN

@interface NA7zzTool : NSObject

+ (nullable NSString *)toolPath;

/// isCancelled is polled while 7zz runs; when it returns YES the task is
/// terminated and the call returns NO with NSUserCancelledError.
+ (BOOL)extractArchiveAtPath:(NSString *)archivePath
               toDestination:(NSString *)destPath
                    progress:(nullable NAExtractionProgressBlock)progressBlock
                 isCancelled:(nullable BOOL (^)(void))isCancelled
                       error:(NSError **)error;

+ (nullable NSArray<NSString *> *)contentsOfArchiveAtPath:(NSString *)path
                                                    error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
