#import <Foundation/Foundation.h>
#import "NAExtractorPlugin.h"

NS_ASSUME_NONNULL_BEGIN

@interface NAPluginManager : NSObject

+ (instancetype)sharedManager;

- (void)loadPlugins;
- (void)registerBuiltinClass:(Class<NAExtractorPlugin>)cls;

/// Registers the extractors shipped with the app. Sniffing uses the first
/// match in registration order, so format-specific extractors (7z, RAR) are
/// registered before NALibarchiveExtractor, which can also read those formats.
- (void)registerBuiltinExtractors;

- (nullable id<NAExtractorPlugin>)extractorForFileAtPath:(NSString *)path;
- (NSArray<Class<NAExtractorPlugin>> *)allPluginClasses;

@end

NS_ASSUME_NONNULL_END
