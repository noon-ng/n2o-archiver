#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface NAExtractionWindowController : NSWindowController

- (instancetype)initWithArchivePath:(NSString *)archivePath;

/// Shows the window and extracts the archive with an NAExtractionJob. Progress
/// is shown in the window; errors are shown in a sheet.
- (void)beginExtraction;

/// YES from beginExtraction until the extraction has returned and, if it failed
/// or was cancelled, its output has been removed.
@property (nonatomic, readonly, getter=isWorking) BOOL working;

/// Cancels a running extraction. The window closes after the extractor has
/// returned and the partial output has been removed. Closes the window
/// directly when no extraction is running.
- (void)cancelExtraction:(nullable id)sender;

@end

NS_ASSUME_NONNULL_END
