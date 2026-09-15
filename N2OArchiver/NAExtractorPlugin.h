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

/// Asks a running extractArchiveAtPath:toDestination:progress:error: call to
/// stop. May be called from any thread, including before extraction starts.
/// The extraction call then returns NO with NSUserCancelledError in
/// NSCocoaErrorDomain. Files already written are left for the caller to remove.
- (void)cancelExtraction;

@end

NS_ASSUME_NONNULL_END
