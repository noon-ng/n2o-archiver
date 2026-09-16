#import "NATestCase.h"
#import "NATestFixtures.h"
#import "NAPluginManager.h"
#import "Plugins/NALibarchiveExtractor.h"
#import "Plugins/NA7zExtractor.h"

@interface NAPluginManagerTests : NATestCase
@end

@implementation NAPluginManagerTests

#pragma mark - Registration

- (void)testRegisterBuiltinClass {
    NAPluginManager *pm = [[NAPluginManager alloc] init];
    [pm registerExtractorClass:[NALibarchiveExtractor class]];
    NAAssertEqual([pm allPluginClasses].count, 1u,
                  @"should have one registered class");
}

- (void)testDuplicateRegistration {
    NAPluginManager *pm = [[NAPluginManager alloc] init];
    [pm registerExtractorClass:[NALibarchiveExtractor class]];
    [pm registerExtractorClass:[NALibarchiveExtractor class]];
    NAAssertEqual([pm allPluginClasses].count, 1u,
                  @"duplicate registration should be ignored");
}

#pragma mark - Format routing by extension

- (void)testExtractorForZipByPath {
    NAPluginManager *pm = [[NAPluginManager alloc] init];
    [pm registerExtractorClass:[NALibarchiveExtractor class]];

    id<NAExtractorPlugin> ext = [pm extractorForFileAtURL:[NATestFixtures URLForFixture:@"test.zip"]];
    NAAssertNotNil(ext, @"should find extractor for .zip");
    NAAssertTrue([ext isKindOfClass:[NALibarchiveExtractor class]],
                 @"should be NALibarchiveExtractor");
}

- (void)testExtractorForTarGzByPath {
    NAPluginManager *pm = [[NAPluginManager alloc] init];
    [pm registerExtractorClass:[NALibarchiveExtractor class]];

    id<NAExtractorPlugin> ext = [pm extractorForFileAtURL:[NATestFixtures URLForFixture:@"test.tar.gz"]];
    NAAssertNotNil(ext, @"should find extractor for .tar.gz");
}

#pragma mark - Magic-byte sniffing

- (void)testMagicByteSniffingPriority {
    NAPluginManager *pm = [[NAPluginManager alloc] init];
    [pm registerExtractorClass:[NALibarchiveExtractor class]];

    // Rename a zip to have no extension — magic bytes should still match.
    NSString *src = [NATestFixtures pathForFixture:@"test.zip"];
    NSString *noExt = [NATestFixtures pathForFixture:@"mystery_archive"];
    [[NSFileManager defaultManager] copyItemAtPath:src toPath:noExt error:nil];

    id<NAExtractorPlugin> ext = [pm extractorForFileAtURL:NAFileURL(noExt)];
    NAAssertNotNil(ext, @"should find extractor via magic bytes even without extension");

    [[NSFileManager defaultManager] removeItemAtPath:noExt error:nil];
}

#pragma mark - Built-in routing

- (void)testBuiltinRouting7zUses7zExtractor {
    NAPluginManager *pm = [[NAPluginManager alloc] init];
    [pm registerBuiltinExtractors];
    id<NAExtractorPlugin> ext = [pm extractorForFileAtURL:[NATestFixtures URLForFixture:@"test.7z"]];
    NAAssertTrue([ext isKindOfClass:[NA7zExtractor class]],
                 @".7z should route to NA7zExtractor, got %@", [ext class]);
}

// Homebrew's 7zz is built without the RAR codec, so RAR goes to libarchive.
- (void)testBuiltinRoutingRarUsesLibarchive {
    NAPluginManager *pm = [[NAPluginManager alloc] init];
    [pm registerBuiltinExtractors];
    id<NAExtractorPlugin> ext = [pm extractorForFileAtURL:[NATestFixtures URLForFixture:@"test.rar"]];
    NAAssertTrue([ext isKindOfClass:[NALibarchiveExtractor class]],
                 @".rar should route to NALibarchiveExtractor, got %@", [ext class]);
}

- (void)testBuiltinRoutingZipUsesLibarchive {
    NAPluginManager *pm = [[NAPluginManager alloc] init];
    [pm registerBuiltinExtractors];
    id<NAExtractorPlugin> ext = [pm extractorForFileAtURL:[NATestFixtures URLForFixture:@"test.zip"]];
    NAAssertTrue([ext isKindOfClass:[NALibarchiveExtractor class]],
                 @".zip should route to NALibarchiveExtractor, got %@", [ext class]);
}

#pragma mark - Plugin signatures

- (void)testAdHocSignedPluginIsNotLoaded {
    NAPluginManager *pm = [[NAPluginManager alloc] init];
    NSString *dir = [NATestFixtures fixtureDir];
    [pm loadPluginsFromDirectoryURLs:@[NAFileURL(dir)]];

    NSBundle *bundle = [NSBundle bundleWithPath:
        [dir stringByAppendingPathComponent:@"AdHocSignedPlugin.bundle"]];
    NAAssertFalse(bundle.isLoaded, @"an ad-hoc signed plugin should not be loaded");
    NAAssertEqual([pm allPluginClasses].count, 0u,
                  @"an ad-hoc signed plugin should not be registered");
}

- (void)testAdHocSignedPluginIsNotTrusted {
    NSError *error = nil;
    BOOL trusted = [NAPluginManager isTrustedPluginAtURL:NAFileURL([[NATestFixtures fixtureDir] stringByAppendingPathComponent:@"AdHocSignedPlugin.bundle"])
                                                    error:&error];
    NAAssertFalse(trusted, @"an ad-hoc signature is not issued by Apple");
    NAAssertNotNil(error, @"the rejection should carry an error");
}

- (void)testAppleSignedBundleIsTrusted {
    NSError *error = nil;
    BOOL trusted = [NAPluginManager isTrustedPluginAtURL:NAFileURL(@"/System/Applications/Calculator.app")
                                                    error:&error];
    NAAssertTrue(trusted, @"an Apple-signed bundle should pass: %@", error);
}

#pragma mark - No match

- (void)testNoExtractorForUnknownFormat {
    NAPluginManager *pm = [[NAPluginManager alloc] init];
    [pm registerExtractorClass:[NALibarchiveExtractor class]];

    // Use a nonexistent file — no magic bytes to sniff, no extension match.
    id<NAExtractorPlugin> ext = [pm extractorForFileAtURL:NAFileURL(@"/nonexistent/file.xyz")];
    NAAssertNil(ext, @"should not find extractor for missing file with unknown extension");
}

- (void)testNoExtractorWhenEmpty {
    NAPluginManager *pm = [[NAPluginManager alloc] init];
    id<NAExtractorPlugin> ext = [pm extractorForFileAtURL:[NATestFixtures URLForFixture:@"test.zip"]];
    NAAssertNil(ext, @"should not find extractor with no plugins registered");
}

#pragma mark - Plugin loading (external bundles)

- (void)testLoadPluginsFromEmptyDirectoryRegistersNothing {
    NAPluginManager *pm = [[NAPluginManager alloc] init];
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"n2o-plugins-%u", arc4random()]];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES
                                               attributes:nil error:nil];

    [pm loadPluginsFromDirectoryURLs:@[NAFileURL(dir),
                                       NAFileURL([dir stringByAppendingPathComponent:@"missing"])]];

    [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
    NAAssertEqual([pm allPluginClasses].count, 0u,
                  @"empty and missing directories should register no plugins");
}

- (void)testDefaultPluginDirectories {
    NSArray<NSURL *> *dirs = [NAPluginManager defaultPluginDirectoryURLs];
    NSString *userDir = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                             NSUserDomainMask, YES).firstObject
        stringByAppendingPathComponent:@"N2OArchiver/Plugins"];
    NAAssertTrue([dirs containsObject:NSBundle.mainBundle.builtInPlugInsURL],
                 @"the app's PlugIns folder should be scanned, got %@", dirs);
    NAAssertEqualObjects(dirs.lastObject.path, userDir,
                         @"the user's Application Support folder should be scanned, got %@", dirs);
}

@end
