#import "NATestFixtures.h"

static NSString *_fixtureDir;

@implementation NATestFixtures

+ (NSString *)fixtureDir {
    return _fixtureDir;
}

+ (NSString *)pathForFixture:(NSString *)name {
    return [_fixtureDir stringByAppendingPathComponent:name];
}

+ (void)setUp {
    _fixtureDir = [NSTemporaryDirectory()
        stringByAppendingPathComponent:
            [NSString stringWithFormat:@"n2o-archiver-tests-%u", arc4random()]];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *srcDir = [self staticFixturesDir];

    NSError *error = nil;
    if (![fm copyItemAtPath:srcDir toPath:_fixtureDir error:&error]) {
        NSLog(@"NATestFixtures: failed to copy fixtures from %@ to %@: %@",
              srcDir, _fixtureDir, error);
    }
}

+ (void)tearDown {
    if (_fixtureDir) {
        [[NSFileManager defaultManager] removeItemAtPath:_fixtureDir error:nil];
        _fixtureDir = nil;
    }
}

+ (NSString *)staticFixturesDir {
    NSFileManager *fm = [NSFileManager defaultManager];

    // XCTest bundle resources (xcodebuild test).
    for (NSBundle *bundle in [NSBundle allBundles]) {
        NSString *path = [bundle.resourcePath
            stringByAppendingPathComponent:@"Fixtures"];
        if ([fm fileExistsAtPath:path]) return path;
    }

    // Relative to the working directory (make test).
    NSString *cwd = [fm currentDirectoryPath];
    NSString *path = [cwd stringByAppendingPathComponent:@"Tests/Fixtures"];
    if ([fm fileExistsAtPath:path]) return path;

    // Relative to the executable.
    NSString *execDir = NSBundle.mainBundle.bundlePath.stringByDeletingLastPathComponent;
    path = [execDir stringByAppendingPathComponent:@"Tests/Fixtures"];
    if ([fm fileExistsAtPath:path]) return path;

    NSLog(@"NATestFixtures: could not locate Tests/Fixtures directory");
    return @"Tests/Fixtures";
}

+ (NSURL *)fixtureDirURL {
    return [NSURL fileURLWithPath:[self fixtureDir] isDirectory:YES];
}

+ (NSURL *)URLForFixture:(NSString *)name {
    return [NSURL fileURLWithPath:[self pathForFixture:name]];
}

@end
