#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol NAExtractorPlugin <NSObject>

@required

+ (NSArray<NSString *> *)supportedExtensions;
+ (NSArray<NSString *> *)supportedUTIs;

+ (BOOL)canHandleFileAtPath:(NSString *)path;

/// Extracts the archive into the existing directory destPath.
///
/// progress is owned by the caller and may be read from any thread. The
/// extractor sets its totalUnitCount and completedUnitCount as it works (in
/// any unit; completedUnitCount equals totalUnitCount on success) and its
/// fileURL to the item being written. Cancellation is requested with
/// -[NSProgress cancel], possibly before this call starts: the extractor then
/// stops and returns NO with NSUserCancelledError in NSCocoaErrorDomain. Files
/// already written are left for the caller to remove.
- (BOOL)extractArchiveAtPath:(NSString *)archivePath
               toDestination:(NSString *)destPath
                    progress:(NSProgress *)progress
                       error:(NSError **)error;

@optional

- (nullable NSArray<NSString *> *)contentsOfArchiveAtPath:(NSString *)path
                                                    error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
