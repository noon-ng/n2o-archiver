#import <Foundation/Foundation.h>
#import "NAExtractorPlugin.h"

NS_ASSUME_NONNULL_BEGIN

@interface NAPluginManager : NSObject

+ (instancetype)sharedManager;

/// Contents/PlugIns of the main bundle and
/// ~/Library/Application Support/N2OArchiver/Plugins.
+ (NSArray<NSString *> *)defaultPluginDirectories;

/// Loads trusted plugin bundles from the given directories.
- (void)loadPluginsFromDirectories:(NSArray<NSString *> *)directories;

/// YES when the bundle at path has a valid code signature from an
/// Apple-issued certificate (Developer ID or App Store), including nested
/// code. Plugins that fail this check are not loaded.
+ (BOOL)isTrustedPluginAtPath:(NSString *)path error:(NSError **)error;
/// Adds an extractor class after those already registered; used for built-in
/// extractors and for classes from loaded plugin bundles.
- (void)registerExtractorClass:(Class<NAExtractorPlugin>)cls;

/// Registers the extractors shipped with the app. Sniffing uses the first
/// match in registration order, so NA7zExtractor is registered before
/// NALibarchiveExtractor, which can also read 7z. RAR is extracted by
/// libarchive: Homebrew's 7zz is built without the RAR codec.
- (void)registerBuiltinExtractors;

- (nullable id<NAExtractorPlugin>)extractorForFileAtPath:(NSString *)path;
- (NSArray<Class<NAExtractorPlugin>> *)allPluginClasses;

@end

NS_ASSUME_NONNULL_END
