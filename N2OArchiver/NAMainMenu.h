#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface NAMainMenu : NSObject

/// The application's main menu: the standard application, File, Edit and
/// Window menus. The Services and Window menus are returned through the out
/// parameters so the caller can hand them to NSApplication.
+ (NSMenu *)menuWithServicesMenu:(NSMenu *_Nullable *_Nullable)servicesMenu
                      windowMenu:(NSMenu *_Nullable *_Nullable)windowMenu;

@end

NS_ASSUME_NONNULL_END
