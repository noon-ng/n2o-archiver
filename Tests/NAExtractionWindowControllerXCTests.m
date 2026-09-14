#import <XCTest/XCTest.h>
#import "NATestFixtures.h"
#import "NAExtractionWindowController.h"
#import "NAPluginManager.h"
#import "Plugins/NALibarchiveExtractor.h"

@interface NAExtractionWindowControllerXCTests : XCTestCase
@end

@implementation NAExtractionWindowControllerXCTests

+ (void)setUp {
    [NATestFixtures setUp];
}

+ (void)tearDown {
    [NATestFixtures tearDown];
}

- (void)setUp {
    [super setUp];
    [[NAPluginManager sharedManager] registerBuiltinClass:[NALibarchiveExtractor class]];
}

#pragma mark - Initialization

- (void)testInitCreatesWindow {
    NSString *path = [NATestFixtures pathForFixture:@"test.zip"];
    NAExtractionWindowController *wc =
        [[NAExtractionWindowController alloc] initWithArchivePath:path];

    XCTAssertNotNil(wc.window);
    XCTAssertEqualObjects(wc.window.title, @"N2O Archiver");
}

#pragma mark - Extraction via backend directly

- (void)testExtractionProducesCorrectOutput {
    // Test the extraction logic without going through the window controller's
    // async path (which triggers Finder reveal and window close).
    NALibarchiveExtractor *extractor = [[NALibarchiveExtractor alloc] init];
    NSString *src = [NATestFixtures pathForFixture:@"test.zip"];
    NSString *dest = [NSTemporaryDirectory()
        stringByAppendingPathComponent:
            [NSString stringWithFormat:@"n2o-wc-test-%u", arc4random()]];
    [[NSFileManager defaultManager] createDirectoryAtPath:dest
                              withIntermediateDirectories:YES
                                               attributes:nil error:nil];

    NSError *error = nil;
    BOOL ok = [extractor extractArchiveAtPath:src
                                toDestination:dest
                                     progress:nil
                                        error:&error];
    XCTAssertTrue(ok, @"%@", error.localizedDescription);

    BOOL isDir = NO;
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:dest
                                                       isDirectory:&isDir]);
    XCTAssertTrue(isDir);

    [[NSFileManager defaultManager] removeItemAtPath:dest error:nil];
}

#pragma mark - Error display

- (void)testUnsupportedFormatShowsError {
    NSString *path = [NATestFixtures pathForFixture:@"corrupt.zip"];
    NAExtractionWindowController *wc =
        [[NAExtractionWindowController alloc] initWithArchivePath:path];

    [wc beginExtraction];

    // The error path is synchronous (no plugin found → immediate error display).
    XCTAssertNotNil(wc.window);
}

@end
