#import "NAPluginManager.h"
#import "Plugins/NA7zExtractor.h"
#import "Plugins/NALibarchiveExtractor.h"
#import <Security/Security.h>

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

- (void)registerBuiltinExtractors {
    [self registerBuiltinClass:[NA7zExtractor class]];
    [self registerBuiltinClass:[NALibarchiveExtractor class]];
}

- (void)loadPluginsFromDirectories:(NSArray<NSString *> *)directories {
    for (NSString *dir in directories) {
        NSArray<NSString *> *contents =
            [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir
                                                               error:nil];
        for (NSString *item in contents) {
            if (![item.pathExtension isEqualToString:@"bundle"]) continue;

            NSString *fullPath = [dir stringByAppendingPathComponent:item];

            // Any process running as the user can write to the Application
            // Support folder, so a bundle is loaded only if Apple issued the
            // certificate that signed it.
            NSError *trustError = nil;
            if (![NAPluginManager isTrustedPluginAtPath:fullPath error:&trustError]) {
                NSLog(@"N2OArchiver: not loading plugin without a valid Apple-issued "
                      @"signature: %@ (%@)", fullPath, trustError.localizedDescription);
                continue;
            }

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

+ (BOOL)isTrustedPluginAtPath:(NSString *)path error:(NSError **)error {
    SecStaticCodeRef code = NULL;
    SecRequirementRef requirement = NULL;
    CFErrorRef cfError = NULL;

    OSStatus status = SecStaticCodeCreateWithPath(
        (__bridge CFURLRef)[NSURL fileURLWithPath:path], kSecCSDefaultFlags, &code);
    if (status == errSecSuccess) {
        // Developer ID and App Store certificates chain to Apple's root CA.
        status = SecRequirementCreateWithString(CFSTR("anchor apple generic"),
                                                kSecCSDefaultFlags, &requirement);
    }
    if (status == errSecSuccess) {
        status = SecStaticCodeCheckValidityWithErrors(
            code,
            kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate,
            requirement, &cfError);
    }

    if (code) CFRelease(code);
    if (requirement) CFRelease(requirement);

    if (status == errSecSuccess) return YES;

    NSError *reason = cfError
        ? (NSError *)CFBridgingRelease(cfError)
        : [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil];
    if (error) *error = reason;
    return NO;
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

+ (NSArray<NSString *> *)defaultPluginDirectories {
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
