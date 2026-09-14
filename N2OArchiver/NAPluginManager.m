#import "NAPluginManager.h"

@interface NAPluginManager ()
@property (nonatomic, strong) NSMutableArray<Class<NAExtractorPlugin>> *pluginClasses;
@end

@implementation NAPluginManager

+ (instancetype)sharedManager {
    static NAPluginManager *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[NAPluginManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _pluginClasses = [NSMutableArray array];
    }
    return self;
}

- (void)registerBuiltinClass:(Class<NAExtractorPlugin>)cls {
    if (![self.pluginClasses containsObject:cls]) {
        [self.pluginClasses addObject:cls];
    }
}

- (void)loadPlugins {
    NSArray<NSString *> *searchPaths = [self pluginSearchPaths];

    for (NSString *dir in searchPaths) {
        NSArray<NSString *> *contents =
            [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir
                                                               error:nil];
        for (NSString *item in contents) {
            if (![item.pathExtension isEqualToString:@"bundle"]) continue;

            NSString *fullPath = [dir stringByAppendingPathComponent:item];
            NSBundle *pluginBundle = [NSBundle bundleWithPath:fullPath];
            if (!pluginBundle) continue;

            if (![pluginBundle load]) {
                NSLog(@"N2OArchiver: failed to load plugin bundle: %@", fullPath);
                continue;
            }

            Class principalClass = [pluginBundle principalClass];
            if (!principalClass ||
                ![principalClass conformsToProtocol:@protocol(NAExtractorPlugin)]) {
                NSLog(@"N2OArchiver: plugin principal class does not conform "
                      @"to NAExtractorPlugin: %@", fullPath);
                continue;
            }

            [self registerBuiltinClass:(Class<NAExtractorPlugin>)principalClass];
            NSLog(@"N2OArchiver: loaded plugin: %@ (%@)",
                  item, NSStringFromClass(principalClass));
        }
    }
}

- (nullable id<NAExtractorPlugin>)extractorForFileAtPath:(NSString *)path {
    // First pass: ask each plugin to sniff the file (magic bytes).
    for (Class cls in self.pluginClasses) {
        if ([cls canHandleFileAtPath:path]) {
            return [[(Class)cls alloc] init];
        }
    }

    // Second pass: match by file extension.
    NSString *ext = path.pathExtension.lowercaseString;
    if (ext.length == 0) return nil;

    for (Class cls in self.pluginClasses) {
        NSArray<NSString *> *supported = [cls supportedExtensions];
        for (NSString *supportedExt in supported) {
            if ([supportedExt.lowercaseString isEqualToString:ext]) {
                return [[(Class)cls alloc] init];
            }
        }
    }

    return nil;
}

- (NSArray<Class<NAExtractorPlugin>> *)allPluginClasses {
    return [self.pluginClasses copy];
}

#pragma mark - Private

- (NSArray<NSString *> *)pluginSearchPaths {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];

    // Built-in plugins inside the app bundle.
    NSString *builtIn = [NSBundle.mainBundle builtInPlugInsPath];
    if (builtIn) [paths addObject:builtIn];

    // User-installed plugins.
    NSArray<NSString *> *appSupport =
        NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                            NSUserDomainMask, YES);
    if (appSupport.count > 0) {
        NSString *userPlugins =
            [appSupport[0] stringByAppendingPathComponent:
                @"N2OArchiver/Plugins"];
        [paths addObject:userPlugins];
    }

    return paths;
}

@end
