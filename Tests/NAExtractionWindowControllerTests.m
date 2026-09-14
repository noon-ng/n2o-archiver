#import "NATestCase.h"
#import "NATestFixtures.h"
#import "NAExtractionWindowController.h"
#import "NAPluginManager.h"
#import "Plugins/NALibarchiveExtractor.h"

@interface NAExtractionWindowControllerTests : NATestCase
@end

@implementation NAExtractionWindowControllerTests

- (void)setUp {
    [super setUp];
    // Ensure plugin manager has a backend registered.
    [[NAPluginManager sharedManager] registerBuiltinClass:[NALibarchiveExtractor class]];
}

#pragma mark - Initialization

- (void)testInitCreatesWindow {
    NSString *path = [NATestFixtures pathForFixture:@"test.zip"];
    NAExtractionWindowController *wc =
        [[NAExtractionWindowController alloc] initWithArchivePath:path];

    NAAssertNotNil(wc.window, @"window should be created");
    NAAssertEqualObjects(wc.window.title, @"N2O Archiver",
                         @"window title should be N2O Archiver");
}

#pragma mark - Extraction flow

- (void)testBeginExtractionCreatesOutput {
    NSString *path = [NATestFixtures pathForFixture:@"test.zip"];
    NAExtractionWindowController *wc =
        [[NAExtractionWindowController alloc] initWithArchivePath:path];

    [wc beginExtraction];

    // Extraction runs asynchronously — wait briefly.
    NSDate *timeout = [NSDate dateWithTimeIntervalSinceNow:5.0];
    while ([[NSDate date] compare:timeout] == NSOrderedAscending) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }

    // Verify extraction output exists.
    NSString *expectedDir = [[NATestFixtures fixtureDir]
        stringByAppendingPathComponent:@"test"];
    BOOL isDir = NO;
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:expectedDir
                                                       isDirectory:&isDir];
    NAAssertTrue(exists && isDir,
                 @"extraction should create output directory at %@", expectedDir);

    // Clean up.
    [[NSFileManager defaultManager] removeItemAtPath:expectedDir error:nil];
}

#pragma mark - Error display

- (void)testUnsupportedFormatShowsError {
    NSString *path = [NATestFixtures pathForFixture:@"corrupt.zip"];
    NAExtractionWindowController *wc =
        [[NAExtractionWindowController alloc] initWithArchivePath:path];

    [wc beginExtraction];

    // Wait for the error to be displayed.
    NSDate *timeout = [NSDate dateWithTimeIntervalSinceNow:2.0];
    while ([[NSDate date] compare:timeout] == NSOrderedAscending) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }

    // Window should still exist (not auto-closed on error).
    NAAssertNotNil(wc.window, @"window should remain open on error");
}

@end
