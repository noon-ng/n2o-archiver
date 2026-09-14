#import <Foundation/Foundation.h>
#import "NAExtractorPlugin.h"

NS_ASSUME_NONNULL_BEGIN

@interface NAPluginManager : NSObject

+ (instancetype)sharedManager;

- (void)loadPlugins;
- (void)registerBuiltinClass:(Class<NAExtractorPlugin>)cls;

- (nullable id<NAExtractorPlugin>)extractorForFileAtPath:(NSString *)path;
- (NSArray<Class<NAExtractorPlugin>> *)allPluginClasses;

@end

NS_ASSUME_NONNULL_END
