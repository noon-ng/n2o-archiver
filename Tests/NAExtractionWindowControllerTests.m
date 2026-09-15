#import "NATestCase.h"
#import "NATestFixtures.h"
#import "NAExtractionWindowController.h"
#import "NAPluginManager.h"
#import "Plugins/NALibarchiveExtractor.h"

@interface NAExtractionWindowControllerTests : NATestCase
@end

// Private methods under test.
@interface NAExtractionWindowController (Testing)
- (NSString *)createDestinationForArchive:(NSString *)archivePath
                                    error:(NSError **)error;
- (void)unwrapSingleItemDirectoryAtPath:(NSString *)destPath;
- (void)cancelExtraction:(id)sender;
@end

@interface NAExtractionWindowControllerTests ()
@property (nonatomic, copy) NSString *unwrapDir;
@property (nonatomic, strong) NAExtractionWindowController *unwrapController;
@end

@implementation NAExtractionWindowControllerTests

- (void)tearDown {
    if (self.unwrapDir) {
        [[NSFileManager defaultManager] removeItemAtPath:self.unwrapDir error:nil];
        self.unwrapDir = nil;
    }
    [super tearDown];
}

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

#pragma mark - Destination directory

- (void)testDestinationUsesArchiveBaseName {
    NSString *dir = [self makeUnwrapDestination];
    NSString *archive = [self copyFixture:@"test.zip" to:@"test.zip" under:dir];

    NSError *error = nil;
    NSString *dest = [self.unwrapController createDestinationForArchive:archive
                                                                   error:&error];

    NAAssertEqualObjects(dest, [dir stringByAppendingPathComponent:@"test"],
                         @"destination should be the archive base name, got %@ (%@)",
                         dest, error);
    NAAssertTrue([self fileExists:@"test" under:dir], @"destination should be created");
}

- (void)testDestinationSkipsExistingDirectory {
    NSString *dir = [self makeUnwrapDestination];
    NSString *archive = [self copyFixture:@"test.zip" to:@"test.zip" under:dir];
    [self writeFile:@"test/keep.txt" under:dir];

    NSString *dest = [self.unwrapController createDestinationForArchive:archive
                                                                   error:nil];

    NAAssertEqualObjects(dest, [dir stringByAppendingPathComponent:@"test 2"],
                         @"existing directory should not be reused, got %@", dest);
    NAAssertEqual([[NSFileManager defaultManager]
                      contentsOfDirectoryAtPath:[dir stringByAppendingPathComponent:@"test"]
                                          error:nil].count, 1u,
                  @"existing directory should be unchanged");
}

- (void)testDestinationSkipsArchiveWithoutExtension {
    NSString *dir = [self makeUnwrapDestination];
    NSString *archive = [self copyFixture:@"test.zip" to:@"mystery" under:dir];

    NSString *dest = [self.unwrapController createDestinationForArchive:archive
                                                                   error:nil];

    NAAssertEqualObjects(dest, [dir stringByAppendingPathComponent:@"mystery 2"],
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

    NAAssertTrue([self fileExists:@"test/keep.txt" under:dir],
                 @"cancel should not remove a directory that existed before extraction");
    NAAssertFalse([self fileExists:@"test 2" under:dir],
                  @"cancel should remove the directory created for the extraction");
}

- (NSString *)copyFixture:(NSString *)fixture to:(NSString *)name under:(NSString *)dir {
    NSString *path = [dir stringByAppendingPathComponent:name];
    [[NSFileManager defaultManager] copyItemAtPath:[NATestFixtures pathForFixture:fixture]
                                            toPath:path error:nil];
    return path;
}

#pragma mark - Unwrapping a single top-level directory

- (void)testUnwrapMovesDirectoryContentsUp {
    NSString *dest = [self makeUnwrapDestination];
    [self writeFile:@"inner/a.txt" under:dest];
    [self writeFile:@"inner/sub/b.txt" under:dest];

    [self.unwrapController unwrapSingleItemDirectoryAtPath:dest];

    NAAssertTrue([self fileExists:@"a.txt" under:dest], @"a.txt should move up");
    NAAssertTrue([self fileExists:@"sub/b.txt" under:dest], @"sub/b.txt should move up");
    NAAssertFalse([self fileExists:@"inner" under:dest], @"inner should be removed");
}

- (void)testUnwrapChildWithSameNameAsDirectory {
    NSString *dest = [self makeUnwrapDestination];
    [self writeFile:@"x/x/important.txt" under:dest];

    [self.unwrapController unwrapSingleItemDirectoryAtPath:dest];

    NAAssertTrue([self fileExists:@"x/important.txt" under:dest],
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

    NAAssertTrue([self fileExists:@"outside/keep.txt" under:dest],
                 @"files in the symlinked directory should not be moved");
    NAAssertFalse([self fileExists:@"keep.txt" under:out],
                  @"symlinked directory contents should not appear in the destination");
}

- (void)testUnwrapSkippedWhenHiddenItemPresent {
    NSString *dest = [self makeUnwrapDestination];
    [self writeFile:@".hidden" under:dest];
    [self writeFile:@"dir/.hidden" under:dest];

    [self.unwrapController unwrapSingleItemDirectoryAtPath:dest];

    NAAssertTrue([self fileExists:@".hidden" under:dest], @"top-level .hidden should remain");
    NAAssertTrue([self fileExists:@"dir/.hidden" under:dest], @"dir/.hidden should remain");
}

- (void)testUnwrapRestoresLayoutWhenMoveFails {
    NSString *dest = [self makeUnwrapDestination];
    [self writeFile:@".DS_Store" under:dest];
    [self writeFile:@"inner/.DS_Store" under:dest];
    [self writeFile:@"inner/a.txt" under:dest];

    [self.unwrapController unwrapSingleItemDirectoryAtPath:dest];

    NAAssertTrue([self fileExists:@"inner/.DS_Store" under:dest],
                 @"inner/.DS_Store should be restored");
    NAAssertTrue([self fileExists:@"inner/a.txt" under:dest],
                 @"inner/a.txt should be restored");
    NAAssertEqual([[NSFileManager defaultManager]
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
