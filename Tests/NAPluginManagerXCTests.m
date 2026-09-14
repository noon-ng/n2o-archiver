#import <XCTest/XCTest.h>
#import "NATestFixtures.h"
#import "NAPluginManager.h"
#import "Plugins/NALibarchiveExtractor.h"
#import "Plugins/NA7zExtractor.h"
#import "Plugins/NARarExtractor.h"

@interface NAPluginManagerXCTests : XCTestCase
@end

@implementation NAPluginManagerXCTests

+ (void)setUp {
    [NATestFixtures setUp];
}

+ (void)tearDown {
    [NATestFixtures tearDown];
}

#pragma mark - Registration

- (void)testRegisterBuiltinClass {
    NAPluginManager *pm = [[NAPluginManager alloc] init];
    [pm registerBuiltinClass:[NALibarchiveExtractor class]];
    XCTAssertEqual([pm allPluginClasses].count, 1u);
}

- (void)testDuplicateRegistration {
    NAPluginManager *pm = [[NAPluginManager alloc] init];
    [pm registerBuiltinClass:[NALibarchiveExtractor class]];
    [pm registerBuiltinClass:[NALibarchiveExtractor class]];
    XCTAssertEqual([pm allPluginClasses].count, 1u);
}

#pragma mark - Format routing by extension

- (void)testExtractorForZipByPath {
    NAPluginManager *pm = [[NAPluginManager alloc] init];
    [pm registerBuiltinClass:[NALibarchiveExtractor class]];

    id<NAExtractorPlugin> ext = [pm extractorForFileAtPath:
        [NATestFixtures pathForFixture:@"test.zip"]];
    XCTAssertNotNil(ext);
    XCTAssertTrue([ext isKindOfClass:[NALibarchiveExtractor class]]);
}

- (void)testExtractorForTarGzByPath {
    NAPluginManager *pm = [[NAPluginManager alloc] init];
    [pm registerBuiltinClass:[NALibarchiveExtractor class]];

    id<NAExtractorPlugin> ext = [pm extractorForFileAtPath:
        [NATestFixtures pathForFixture:@"test.tar.gz"]];
    XCTAssertNotNil(ext);
}

#pragma mark - Magic-byte sniffing

- (void)testMagicByteSniffingPriority {
    NAPluginManager *pm = [[NAPluginManager alloc] init];
    [pm registerBuiltinClass:[NALibarchiveExtractor class]];

    NSString *src = [NATestFixtures pathForFixture:@"test.zip"];
    NSString *noExt = [NATestFixtures pathForFixture:@"mystery_archive"];
    [[NSFileManager defaultManager] copyItemAtPath:src toPath:noExt error:nil];

    id<NAExtractorPlugin> ext = [pm extractorForFileAtPath:noExt];
    XCTAssertNotNil(ext);

    [[NSFileManager defaultManager] removeItemAtPath:noExt error:nil];
}

#pragma mark - Built-in routing

- (void)testBuiltinRouting7zUses7zExtractor {
    NAPluginManager *pm = [[NAPluginManager alloc] init];
    [pm registerBuiltinExtractors];
    id<NAExtractorPlugin> ext = [pm extractorForFileAtPath:
        [NATestFixtures pathForFixture:@"test.7z"]];
    XCTAssertTrue([ext isKindOfClass:[NA7zExtractor class]],
                 @".7z should route to NA7zExtractor, got %@", [ext class]);
}

- (void)testBuiltinRoutingRarUsesRarExtractor {
    NAPluginManager *pm = [[NAPluginManager alloc] init];
    [pm registerBuiltinExtractors];
    id<NAExtractorPlugin> ext = [pm extractorForFileAtPath:
        [NATestFixtures pathForFixture:@"test.rar"]];
    XCTAssertTrue([ext isKindOfClass:[NARarExtractor class]],
                 @".rar should route to NARarExtractor, got %@", [ext class]);
}

- (void)testBuiltinRoutingZipUsesLibarchive {
    NAPluginManager *pm = [[NAPluginManager alloc] init];
    [pm registerBuiltinExtractors];
    id<NAExtractorPlugin> ext = [pm extractorForFileAtPath:
        [NATestFixtures pathForFixture:@"test.zip"]];
    XCTAssertTrue([ext isKindOfClass:[NALibarchiveExtractor class]],
                 @".zip should route to NALibarchiveExtractor, got %@", [ext class]);
}

#pragma mark - No match

- (void)testNoExtractorForUnknownFormat {
    NAPluginManager *pm = [[NAPluginManager alloc] init];
    [pm registerBuiltinClass:[NALibarchiveExtractor class]];

    id<NAExtractorPlugin> ext = [pm extractorForFileAtPath:@"/nonexistent/file.xyz"];
    XCTAssertNil(ext);
}

- (void)testNoExtractorWhenEmpty {
    NAPluginManager *pm = [[NAPluginManager alloc] init];
    id<NAExtractorPlugin> ext = [pm extractorForFileAtPath:
        [NATestFixtures pathForFixture:@"test.zip"]];
    XCTAssertNil(ext);
}

#pragma mark - Plugin loading

- (void)testLoadPluginsDoesNotCrashOnEmptyDirectory {
    NAPluginManager *pm = [[NAPluginManager alloc] init];
    [pm loadPlugins];
}

@end
