#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface AppDelegate : NSObject <NSApplicationDelegate>

/// Directories scanned for plugin bundles at launch. Defaults to
/// +[NAPluginManager defaultPluginDirectoryURLs].
@property (nonatomic, copy) NSArray<NSURL *> *pluginDirectoryURLs;

/// When set, replaces the Finder reveal of each extraction window.
@property (nonatomic, copy, nullable) void (^revealHandler)(NSURL *url);

@end

NS_ASSUME_NONNULL_END
