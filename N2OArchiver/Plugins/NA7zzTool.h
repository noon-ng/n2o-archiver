#import <Foundation/Foundation.h>
#import "NAExtractorPlugin.h"

NS_ASSUME_NONNULL_BEGIN

@interface NA7zzTool : NSObject

+ (nullable NSString *)toolPath;

+ (BOOL)extractArchiveAtPath:(NSString *)archivePath
               toDestination:(NSString *)destPath
                    progress:(nullable NAExtractionProgressBlock)progressBlock
                       error:(NSError **)error;

+ (nullable NSArray<NSString *> *)contentsOfArchiveAtPath:(NSString *)path
                                                    error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
