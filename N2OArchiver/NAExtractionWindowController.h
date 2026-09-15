#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface NAExtractionWindowController : NSWindowController

- (instancetype)initWithArchivePath:(NSString *)archivePath;
- (void)beginExtraction;

/// YES from beginExtraction until the extraction has returned and, if it was
/// cancelled, its output has been removed.
@property (nonatomic, readonly, getter=isWorking) BOOL working;

/// Cancels a running extraction. The window closes after the extractor has
/// returned and the partial output has been removed. Closes the window
/// directly when no extraction is running.
- (void)cancelExtraction:(nullable id)sender;

@end

NS_ASSUME_NONNULL_END
