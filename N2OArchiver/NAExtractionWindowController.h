#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface NAExtractionWindowController : NSWindowController

- (instancetype)initWithArchivePath:(NSString *)archivePath;
- (void)beginExtraction;

@end

NS_ASSUME_NONNULL_END
