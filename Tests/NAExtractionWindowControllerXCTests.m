#import <XCTest/XCTest.h>
#import "NATestFixtures.h"
#import "NAExtractionWindowController.h"
#import "NAPluginManager.h"
#import "Plugins/NALibarchiveExtractor.h"

@interface NAExtractionWindowControllerXCTests : XCTestCase
@end

// Private methods under test.
@interface NAExtractionWindowController (Testing)
- (NSString *)createDestinationForArchive:(NSString *)archivePath
                                    error:(NSError **)error;
- (void)unwrapSingleItemDirectoryAtPath:(NSString *)destPath;
- (BOOL)windowShouldClose:(NSWindow *)sender;
@end

@interface NAExtractionWindowControllerXCTests ()
@property (nonatomic, copy) NSString *unwrapDir;
@property (nonatomic, strong) NAExtractionWindowController *unwrapController;
@end

@implementation NAExtractionWindowControllerXCTests

- (void)tearDown {
    if (self.unwrapDir) {
        [[NSFileManager defaultManager] removeItemAtPath:self.unwrapDir error:nil];
        self.unwrapDir = nil;
    }
    [super tearDown];
}

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

#pragma mark - Destination directory

- (void)testDestinationUsesArchiveBaseName {
    NSString *dir = [self makeUnwrapDestination];
    NSString *archive = [self copyFixture:@"test.zip" to:@"test.zip" under:dir];

    NSError *error = nil;
    NSString *dest = [self.unwrapController createDestinationForArchive:archive
                                                                   error:&error];

    XCTAssertEqualObjects(dest, [dir stringByAppendingPathComponent:@"test"],
                         @"destination should be the archive base name, got %@ (%@)",
                         dest, error);
    XCTAssertTrue([self fileExists:@"test" under:dir], @"destination should be created");
}

- (void)testDestinationSkipsExistingDirectory {
    NSString *dir = [self makeUnwrapDestination];
    NSString *archive = [self copyFixture:@"test.zip" to:@"test.zip" under:dir];
    [self writeFile:@"test/keep.txt" under:dir];

    NSString *dest = [self.unwrapController createDestinationForArchive:archive
                                                                   error:nil];

    XCTAssertEqualObjects(dest, [dir stringByAppendingPathComponent:@"test 2"],
                         @"existing directory should not be reused, got %@", dest);
    XCTAssertEqual([[NSFileManager defaultManager]
                      contentsOfDirectoryAtPath:[dir stringByAppendingPathComponent:@"test"]
                                          error:nil].count, 1u,
                  @"existing directory should be unchanged");
}

- (void)testDestinationSkipsArchiveWithoutExtension {
    NSString *dir = [self makeUnwrapDestination];
    NSString *archive = [self copyFixture:@"test.zip" to:@"mystery" under:dir];

    NSString *dest = [self.unwrapController createDestinationForArchive:archive
                                                                   error:nil];

    XCTAssertEqualObjects(dest, [dir stringByAppendingPathComponent:@"mystery 2"],
                         @"archive file itself should not be used as destination, got %@",
                         dest);
}

- (void)testCancelKeepsExistingDirectory {
    NSString *dir = [self makeUnwrapDestination];
    NSString *archive = [self copyFixture:@"test.zip" to:@"test.zip" under:dir];
    [self writeFile:@"test/keep.txt" under:dir];

    NAExtractionWindowController *wc =
        [[NAExtractionWindowController alloc] initWithArchivePath:archive];
    [wc beginExtraction];
    [wc cancelExtraction:nil];

    NSDate *timeout = [NSDate dateWithTimeIntervalSinceNow:2.0];
    while ([[NSDate date] compare:timeout] == NSOrderedAscending) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }

    XCTAssertTrue([self fileExists:@"test/keep.txt" under:dir],
                 @"cancel should not remove a directory that existed before extraction");
    XCTAssertFalse([self fileExists:@"test 2" under:dir],
                  @"cancel should remove the directory created for the extraction");
}

- (NSString *)copyFixture:(NSString *)fixture to:(NSString *)name under:(NSString *)dir {
    NSString *path = [dir stringByAppendingPathComponent:name];
    [[NSFileManager defaultManager] copyItemAtPath:[NATestFixtures pathForFixture:fixture]
                                            toPath:path error:nil];
    return path;
}

#pragma mark - Cancellation

- (void)testCancelKeepsWindowOpenUntilExtractionReturns {
    NSString *dir = [self makeUnwrapDestination];
    NSString *archive = [self copyFixture:@"test.zip" to:@"test.zip" under:dir];
    NAExtractionWindowController *wc =
        [[NAExtractionWindowController alloc] initWithArchivePath:archive];

    [wc beginExtraction];
    [wc cancelExtraction:nil];

    // The completion block is queued on the main queue, so it has not run yet.
    XCTAssertTrue(wc.window.isVisible,
                 @"window should stay open until the extraction has returned");
    XCTAssertTrue(wc.isWorking, @"controller should report work in progress");

    [self spinRunLoopFor:2.0];

    XCTAssertFalse(wc.isWorking, @"work should be finished after cleanup");
    XCTAssertFalse(wc.window.isVisible, @"window should close after cleanup");
    XCTAssertFalse([self fileExists:@"test" under:dir],
                  @"output of the cancelled extraction should be removed");
}

- (void)testClosingWindowDuringExtractionCancels {
    NSString *dir = [self makeUnwrapDestination];
    NSString *archive = [self copyFixture:@"test.zip" to:@"test.zip" under:dir];
    NAExtractionWindowController *wc =
        [[NAExtractionWindowController alloc] initWithArchivePath:archive];

    [wc beginExtraction];
    BOOL shouldClose = [wc windowShouldClose:wc.window];

    XCTAssertFalse(shouldClose, @"window should not close while extracting");

    [self spinRunLoopFor:2.0];

    XCTAssertFalse(wc.window.isVisible, @"window should close after cleanup");
    XCTAssertFalse([self fileExists:@"test" under:dir],
                  @"closing during extraction should remove the output");
}

- (void)spinRunLoopFor:(NSTimeInterval)seconds {
    NSDate *timeout = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([[NSDate date] compare:timeout] == NSOrderedAscending) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
}

#pragma mark - Unwrapping a single top-level directory

- (void)testUnwrapMovesDirectoryContentsUp {
    NSString *dest = [self makeUnwrapDestination];
    [self writeFile:@"inner/a.txt" under:dest];
    [self writeFile:@"inner/sub/b.txt" under:dest];

    [self.unwrapController unwrapSingleItemDirectoryAtPath:dest];

    XCTAssertTrue([self fileExists:@"a.txt" under:dest], @"a.txt should move up");
    XCTAssertTrue([self fileExists:@"sub/b.txt" under:dest], @"sub/b.txt should move up");
    XCTAssertFalse([self fileExists:@"inner" under:dest], @"inner should be removed");
}

- (void)testUnwrapChildWithSameNameAsDirectory {
    NSString *dest = [self makeUnwrapDestination];
    [self writeFile:@"x/x/important.txt" under:dest];

    [self.unwrapController unwrapSingleItemDirectoryAtPath:dest];

    XCTAssertTrue([self fileExists:@"x/important.txt" under:dest],
                 @"x/x/important.txt should become x/important.txt");
}

- (void)testUnwrapIgnoresSymlinkToDirectory {
    NSString *dest = [self makeUnwrapDestination];
    NSString *outside = [dest stringByAppendingPathComponent:@"outside"];
    NSString *out = [dest stringByAppendingPathComponent:@"out"];
    [self writeFile:@"outside/keep.txt" under:dest];
    [[NSFileManager defaultManager] createDirectoryAtPath:out
                              withIntermediateDirectories:YES
                                               attributes:nil error:nil];
    [[NSFileManager defaultManager]
        createSymbolicLinkAtPath:[out stringByAppendingPathComponent:@"link"]
             withDestinationPath:outside error:nil];

    [self.unwrapController unwrapSingleItemDirectoryAtPath:out];

    XCTAssertTrue([self fileExists:@"outside/keep.txt" under:dest],
                 @"files in the symlinked directory should not be moved");
    XCTAssertFalse([self fileExists:@"keep.txt" under:out],
                  @"symlinked directory contents should not appear in the destination");
}

- (void)testUnwrapSkippedWhenHiddenItemPresent {
    NSString *dest = [self makeUnwrapDestination];
    [self writeFile:@".hidden" under:dest];
    [self writeFile:@"dir/.hidden" under:dest];

    [self.unwrapController unwrapSingleItemDirectoryAtPath:dest];

    XCTAssertTrue([self fileExists:@".hidden" under:dest], @"top-level .hidden should remain");
    XCTAssertTrue([self fileExists:@"dir/.hidden" under:dest], @"dir/.hidden should remain");
}

- (void)testUnwrapRestoresLayoutWhenMoveFails {
    NSString *dest = [self makeUnwrapDestination];
    [self writeFile:@".DS_Store" under:dest];
    [self writeFile:@"inner/.DS_Store" under:dest];
    [self writeFile:@"inner/a.txt" under:dest];

    [self.unwrapController unwrapSingleItemDirectoryAtPath:dest];

    XCTAssertTrue([self fileExists:@"inner/.DS_Store" under:dest],
                 @"inner/.DS_Store should be restored");
    XCTAssertTrue([self fileExists:@"inner/a.txt" under:dest],
                 @"inner/a.txt should be restored");
    XCTAssertEqual([[NSFileManager defaultManager]
                      contentsOfDirectoryAtPath:dest error:nil].count, 2u,
                  @"destination should contain only .DS_Store and inner");
}

- (NSString *)makeUnwrapDestination {
    self.unwrapDir = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"n2o-unwrap-%u", arc4random()]];
    self.unwrapController = [[NAExtractionWindowController alloc]
        initWithArchivePath:[NATestFixtures pathForFixture:@"test.zip"]];
    [[NSFileManager defaultManager] createDirectoryAtPath:self.unwrapDir
                              withIntermediateDirectories:YES
                                               attributes:nil error:nil];
    return self.unwrapDir;
}

- (void)writeFile:(NSString *)relativePath under:(NSString *)dir {
    NSString *path = [dir stringByAppendingPathComponent:relativePath];
    [[NSFileManager defaultManager]
        createDirectoryAtPath:path.stringByDeletingLastPathComponent
  withIntermediateDirectories:YES attributes:nil error:nil];
    [relativePath writeToFile:path atomically:NO
                     encoding:NSUTF8StringEncoding error:nil];
}

- (BOOL)fileExists:(NSString *)relativePath under:(NSString *)dir {
    return [[NSFileManager defaultManager] fileExistsAtPath:
        [dir stringByAppendingPathComponent:relativePath]];
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
