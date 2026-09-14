#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^NAExtractionProgressBlock)(double fractionComplete,
                                          NSString *currentEntry);

@protocol NAExtractorPlugin <NSObject>

@required

+ (NSArray<NSString *> *)supportedExtensions;
+ (NSArray<NSString *> *)supportedUTIs;

+ (BOOL)canHandleFileAtPath:(NSString *)path;

- (BOOL)extractArchiveAtPath:(NSString *)archivePath
               toDestination:(NSString *)destPath
                    progress:(nullable NAExtractionProgressBlock)progressBlock
                       error:(NSError **)error;

@optional

- (nullable NSArray<NSString *> *)contentsOfArchiveAtPath:(NSString *)path
                                                    error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
