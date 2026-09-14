#import "NATestCase.h"
#import "NATestFixtures.h"
#import "NAPluginManager.h"
#import "Plugins/NALibarchiveExtractor.h"
#import "Plugins/NA7zExtractor.h"
#import "Plugins/NARarExtractor.h"

@interface NAPluginManagerTests : NATestCase
@end

@implementation NAPluginManagerTests

#pragma mark - Registration

- (void)testRegisterBuiltinClass {
    NAPluginManager *pm = [[NAPluginManager alloc] init];
    [pm registerBuiltinClass:[NALibarchiveExtractor class]];
    NAAssertEqual([pm allPluginClasses].count, 1u,
                  @"should have one registered class");
}

- (void)testDuplicateRegistration {
    NAPluginManager *pm = [[NAPluginManager alloc] init];
    [pm registerBuiltinClass:[NALibarchiveExtractor class]];
    [pm registerBuiltinClass:[NALibarchiveExtractor class]];
    NAAssertEqual([pm allPluginClasses].count, 1u,
                  @"duplicate registration should be ignored");
}

#pragma mark - Format routing by extension

- (void)testExtractorForZipByPath {
    NAPluginManager *pm = [[NAPluginManager alloc] init];
    [pm registerBuiltinClass:[NALibarchiveExtractor class]];

    id<NAExtractorPlugin> ext = [pm extractorForFileAtPath:
        [NATestFixtures pathForFixture:@"test.zip"]];
    NAAssertNotNil(ext, @"should find extractor for .zip");
    NAAssertTrue([ext isKindOfClass:[NALibarchiveExtractor class]],
                 @"should be NALibarchiveExtractor");
}

- (void)testExtractorForTarGzByPath {
    NAPluginManager *pm = [[NAPluginManager alloc] init];
    [pm registerBuiltinClass:[NALibarchiveExtractor class]];

    id<NAExtractorPlugin> ext = [pm extractorForFileAtPath:
        [NATestFixtures pathForFixture:@"test.tar.gz"]];
    NAAssertNotNil(ext, @"should find extractor for .tar.gz");
}

#pragma mark - Magic-byte sniffing

- (void)testMagicByteSniffingPriority {
    NAPluginManager *pm = [[NAPluginManager alloc] init];
    [pm registerBuiltinClass:[NALibarchiveExtractor class]];

    // Rename a zip to have no extension — magic bytes should still match.
    NSString *src = [NATestFixtures pathForFixture:@"test.zip"];
    NSString *noExt = [NATestFixtures pathForFixture:@"mystery_archive"];
    [[NSFileManager defaultManager] copyItemAtPath:src toPath:noExt error:nil];

    id<NAExtractorPlugin> ext = [pm extractorForFileAtPath:noExt];
    NAAssertNotNil(ext, @"should find extractor via magic bytes even without extension");

    [[NSFileManager defaultManager] removeItemAtPath:noExt error:nil];
}

#pragma mark - Built-in routing

- (void)testBuiltinRouting7zUses7zExtractor {
    NAPluginManager *pm = [[NAPluginManager alloc] init];
    [pm registerBuiltinExtractors];
    id<NAExtractorPlugin> ext = [pm extractorForFileAtPath:
        [NATestFixtures pathForFixture:@"test.7z"]];
    NAAssertTrue([ext isKindOfClass:[NA7zExtractor class]],
                 @".7z should route to NA7zExtractor, got %@", [ext class]);
}

- (void)testBuiltinRoutingRarUsesRarExtractor {
    NAPluginManager *pm = [[NAPluginManager alloc] init];
    [pm registerBuiltinExtractors];
    id<NAExtractorPlugin> ext = [pm extractorForFileAtPath:
        [NATestFixtures pathForFixture:@"test.rar"]];
    NAAssertTrue([ext isKindOfClass:[NARarExtractor class]],
                 @".rar should route to NARarExtractor, got %@", [ext class]);
}

- (void)testBuiltinRoutingZipUsesLibarchive {
    NAPluginManager *pm = [[NAPluginManager alloc] init];
    [pm registerBuiltinExtractors];
    id<NAExtractorPlugin> ext = [pm extractorForFileAtPath:
        [NATestFixtures pathForFixture:@"test.zip"]];
    NAAssertTrue([ext isKindOfClass:[NALibarchiveExtractor class]],
                 @".zip should route to NALibarchiveExtractor, got %@", [ext class]);
}

#pragma mark - No match

- (void)testNoExtractorForUnknownFormat {
    NAPluginManager *pm = [[NAPluginManager alloc] init];
    [pm registerBuiltinClass:[NALibarchiveExtractor class]];

    // Use a nonexistent file — no magic bytes to sniff, no extension match.
    id<NAExtractorPlugin> ext = [pm extractorForFileAtPath:@"/nonexistent/file.xyz"];
    NAAssertNil(ext, @"should not find extractor for missing file with unknown extension");
}

- (void)testNoExtractorWhenEmpty {
    NAPluginManager *pm = [[NAPluginManager alloc] init];
    id<NAExtractorPlugin> ext = [pm extractorForFileAtPath:
        [NATestFixtures pathForFixture:@"test.zip"]];
    NAAssertNil(ext, @"should not find extractor with no plugins registered");
}

#pragma mark - Plugin loading (external bundles)

- (void)testLoadPluginsDoesNotCrashOnEmptyDirectory {
    NAPluginManager *pm = [[NAPluginManager alloc] init];
    // loadPlugins scans app bundle and ~/Library/Application Support.
    // Neither should have bundles in a test environment; verify no crash.
    [pm loadPlugins];
    // No assertion — just verifying it doesn't throw.
}

@end
