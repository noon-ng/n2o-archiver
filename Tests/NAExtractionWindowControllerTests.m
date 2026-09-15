#import "NATestCase.h"
#import "NATestFixtures.h"
#import "NAWait.h"
#import "NAExtractionWindowController.h"
#include <sys/stat.h>
#include <sys/xattr.h>
#import "NAPluginManager.h"
#import "Plugins/NALibarchiveExtractor.h"

// Extractor for files ending in .n2oscripted. An archive named wait… blocks
// until NAScriptedRelease is signalled, so tests can observe an extraction in
// progress; one named immutable… writes a file with UF_IMMUTABLE and fails.
static dispatch_semaphore_t NAScriptedRelease;

@interface NATestScriptedExtractor : NSObject <NAExtractorPlugin>
@end

@implementation NATestScriptedExtractor

+ (NSArray<NSString *> *)supportedExtensions { return @[@"n2oscripted"]; }
+ (NSArray<NSString *> *)supportedUTIs { return @[]; }
+ (BOOL)canHandleFileAtPath:(NSString *)path {
    return [path.pathExtension isEqualToString:@"n2oscripted"];
}

- (BOOL)extractArchiveAtPath:(NSString *)archivePath
               toDestination:(NSString *)destPath
                    progress:(NAExtractionProgressBlock)progressBlock
                       error:(NSError **)error {
    NSString *file = [destPath stringByAppendingPathComponent:@"payload.txt"];
    [@"payload" writeToFile:file atomically:NO encoding:NSUTF8StringEncoding error:nil];
    NSString *name = archivePath.lastPathComponent;
    if ([name hasPrefix:@"wait"]) {
        dispatch_semaphore_wait(NAScriptedRelease,
                                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)));
    } else if ([name hasPrefix:@"immutable"]) {
        chflags(file.fileSystemRepresentation, UF_IMMUTABLE);
        if (error) {
            *error = [NSError errorWithDomain:@"NATestScriptedExtractor" code:1
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    @"Scripted extraction failure."}];
        }
        return NO;
    }
    return YES;
}

@end

@interface NAExtractionWindowControllerTests : NATestCase
@end

// Private methods under test.
@interface NAExtractionWindowController (Testing)
- (NSString *)moveStagingDirectory:(NSString *)stagingPath
           toDestinationForArchive:(NSString *)archivePath
                             error:(NSError **)error;
- (void)unwrapSingleItemDirectoryAtPath:(NSString *)destPath;
- (BOOL)windowShouldClose:(NSWindow *)sender;
@end

@interface NAExtractionWindowControllerTests ()
@property (nonatomic, copy) NSString *unwrapDir;
@property (nonatomic, strong) NAExtractionWindowController *unwrapController;
@end

@implementation NAExtractionWindowControllerTests

- (void)tearDown {
    if (self.unwrapDir) {
        // Clear flags and restore owner access left by tests.
        for (NSString *item in [[NSFileManager defaultManager] enumeratorAtPath:self.unwrapDir]) {
            const char *path = [self.unwrapDir stringByAppendingPathComponent:item].fileSystemRepresentation;
            struct stat st;
            if (lstat(path, &st) == 0 && !S_ISLNK(st.st_mode)) {
                chflags(path, 0);
                chmod(path, (st.st_mode & 0777) | (S_ISDIR(st.st_mode) ? 0700 : 0600));
            }
        }
        [[NSFileManager defaultManager] removeItemAtPath:self.unwrapDir error:nil];
        self.unwrapDir = nil;
    }
    [super tearDown];
}

- (void)setUp {
    [super setUp];
    // Ensure plugin manager has a backend registered.
    [[NAPluginManager sharedManager] registerBuiltinClass:[NALibarchiveExtractor class]];
    [[NAPluginManager sharedManager] registerBuiltinClass:[NATestScriptedExtractor class]];
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

    NAAssertTrue(NAWaitUntil(^BOOL { return !wc.isWorking; }, 10.0),
                 @"extraction should finish");

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

#pragma mark - Staging directory

- (void)testOutputIsExtractedIntoHiddenStagingDirectory {
    NSString *dir = [self makeUnwrapDestination];
    [self writeFile:@"wait.n2oscripted" under:dir];
    NSString *archive = [dir stringByAppendingPathComponent:@"wait.n2oscripted"];
    const char *value = "0083;00000000;N2OArchiverTests;";
    setxattr(archive.fileSystemRepresentation, "com.apple.quarantine", value, strlen(value), 0, 0);
    NAScriptedRelease = dispatch_semaphore_create(0);

    NAExtractionWindowController *wc =
        [[NAExtractionWindowController alloc] initWithArchivePath:archive];
    [wc beginExtraction];

    NAAssertTrue(NAWaitUntil(^BOOL {
        for (NSString *staging in [self stagingDirectoriesIn:dir]) {
            if ([self fileExists:[staging stringByAppendingPathComponent:@"payload.txt"] under:dir]) return YES;
        }
        return NO;
    }, 10.0), @"files should be written into a hidden .n2o-extract- directory");
    NAAssertFalse([self fileExists:@"wait" under:dir],
                  @"the visible output folder should not exist while extracting");

    dispatch_semaphore_signal(NAScriptedRelease);
    NAAssertTrue(NAWaitUntil(^BOOL { return !wc.isWorking; }, 10.0), @"extraction should finish");

    NAAssertTrue([self fileExists:@"wait/payload.txt" under:dir],
                 @"the staging directory should be renamed to the archive's base name");
    NAAssertEqual([self stagingDirectoriesIn:dir].count, 0u, @"no staging directory should remain");
    char buffer[256];
    ssize_t length = getxattr([dir stringByAppendingPathComponent:@"wait/payload.txt"].fileSystemRepresentation,
                              "com.apple.quarantine", buffer, sizeof(buffer), 0, XATTR_NOFOLLOW);
    NAAssertTrue(length > 0, @"the file should be quarantined before it gets its visible name");
}

- (void)testFailedExtractionAlsoReportsQuarantineFailure {
    NSString *dir = [self makeUnwrapDestination];
    [self writeFile:@"immutable.n2oscripted" under:dir];
    NSString *archive = [dir stringByAppendingPathComponent:@"immutable.n2oscripted"];
    const char *value = "0083;00000000;N2OArchiverTests;";
    setxattr(archive.fileSystemRepresentation, "com.apple.quarantine", value, strlen(value), 0, 0);

    NAExtractionWindowController *wc =
        [[NAExtractionWindowController alloc] initWithArchivePath:archive];
    [wc beginExtraction];
    NAAssertTrue(NAWaitUntil(^BOOL { return !wc.isWorking && wc.window.attachedSheet != nil; }, 10.0),
                 @"the failure should be presented");

    NSError *shown = [wc valueForKey:@"presentedError"];
    NAAssertTrue([shown.localizedRecoverySuggestion containsString:@"Scripted extraction failure."],
                 @"the extraction error should be shown, got %@", shown.localizedRecoverySuggestion);
    NAAssertTrue([shown.localizedRecoverySuggestion containsString:@"could not be marked as downloaded"],
                 @"the quarantine failure should also be shown, got %@", shown.localizedRecoverySuggestion);
    [wc.window endSheet:wc.window.attachedSheet returnCode:NSAlertFirstButtonReturn];
}

- (NSArray<NSString *> *)stagingDirectoriesIn:(NSString *)dir {
    NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
    return [items filteredArrayUsingPredicate:
        [NSPredicate predicateWithFormat:@"SELF BEGINSWITH '.n2o-extract-'"]];
}

#pragma mark - Destination directory

- (void)testDestinationUsesArchiveBaseName {
    NSString *dir = [self makeUnwrapDestination];
    NSString *archive = [self copyFixture:@"test.zip" to:@"test.zip" under:dir];
    [self writeFile:@".n2o-extract-staging/a.txt" under:dir];

    NSError *error = nil;
    NSString *dest = [self.unwrapController
        moveStagingDirectory:[dir stringByAppendingPathComponent:@".n2o-extract-staging"]
     toDestinationForArchive:archive
                       error:&error];

    NAAssertEqualObjects(dest, [dir stringByAppendingPathComponent:@"test"],
                         @"destination should be the archive base name, got %@ (%@)",
                         dest, error);
    NAAssertTrue([self fileExists:@"test/a.txt" under:dir], @"staging contents should move");
    NAAssertFalse([self fileExists:@".n2o-extract-staging" under:dir], @"staging should be gone");
}

- (void)testDestinationSkipsExistingDirectory {
    NSString *dir = [self makeUnwrapDestination];
    NSString *archive = [self copyFixture:@"test.zip" to:@"test.zip" under:dir];
    [self writeFile:@"test/keep.txt" under:dir];
    [self writeFile:@".n2o-extract-staging/a.txt" under:dir];

    NSString *dest = [self.unwrapController
        moveStagingDirectory:[dir stringByAppendingPathComponent:@".n2o-extract-staging"]
     toDestinationForArchive:archive
                       error:nil];

    NAAssertEqualObjects(dest, [dir stringByAppendingPathComponent:@"test 2"],
                         @"existing directory should not be replaced, got %@", dest);
    NAAssertEqual([[NSFileManager defaultManager]
                      contentsOfDirectoryAtPath:[dir stringByAppendingPathComponent:@"test"]
                                          error:nil].count, 1u,
                  @"existing directory should be unchanged");
}

- (void)testDestinationSkipsArchiveWithoutExtension {
    NSString *dir = [self makeUnwrapDestination];
    NSString *archive = [self copyFixture:@"test.zip" to:@"mystery" under:dir];
    [self writeFile:@".n2o-extract-staging/a.txt" under:dir];

    NSString *dest = [self.unwrapController
        moveStagingDirectory:[dir stringByAppendingPathComponent:@".n2o-extract-staging"]
     toDestinationForArchive:archive
                       error:nil];

    NAAssertEqualObjects(dest, [dir stringByAppendingPathComponent:@"mystery 2"],
                         @"archive file itself should not be replaced, got %@", dest);
}

- (void)testCancelKeepsExistingDirectory {
    NSString *dir = [self makeUnwrapDestination];
    NSString *archive = [self copyFixture:@"test.zip" to:@"test.zip" under:dir];
    [self writeFile:@"test/keep.txt" under:dir];

    NAExtractionWindowController *wc =
        [[NAExtractionWindowController alloc] initWithArchivePath:archive];
    [wc beginExtraction];
    [wc cancelExtraction:nil];

    NAAssertTrue(NAWaitUntil(^BOOL { return !wc.isWorking && !wc.window.isVisible; }, 10.0),
                 @"the cancelled extraction should be cleaned up and its window closed");

    NAAssertTrue([self fileExists:@"test/keep.txt" under:dir],
                 @"cancel should not remove a directory that existed before extraction");
    NAAssertFalse([self fileExists:@"test 2" under:dir],
                  @"cancel should remove the directory created for the extraction");
    NAAssertEqual([self stagingDirectoriesIn:dir].count, 0u,
                  @"cancel should remove the staging directory");
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
    NAAssertTrue(wc.window.isVisible,
                 @"window should stay open until the extraction has returned");
    NAAssertTrue(wc.isWorking, @"controller should report work in progress");

    NAAssertTrue(NAWaitUntil(^BOOL { return !wc.isWorking && !wc.window.isVisible; }, 10.0),
                 @"the cancelled extraction should be cleaned up and its window closed");

    NAAssertFalse(wc.isWorking, @"work should be finished after cleanup");
    NAAssertFalse(wc.window.isVisible, @"window should close after cleanup");
    NAAssertFalse([self fileExists:@"test" under:dir],
                  @"output of the cancelled extraction should be removed");
}

- (void)testClosingWindowDuringExtractionCancels {
    NSString *dir = [self makeUnwrapDestination];
    NSString *archive = [self copyFixture:@"test.zip" to:@"test.zip" under:dir];
    NAExtractionWindowController *wc =
        [[NAExtractionWindowController alloc] initWithArchivePath:archive];

    [wc beginExtraction];
    BOOL shouldClose = [wc windowShouldClose:wc.window];

    NAAssertFalse(shouldClose, @"window should not close while extracting");

    NAAssertTrue(NAWaitUntil(^BOOL { return !wc.isWorking && !wc.window.isVisible; }, 10.0),
                 @"the cancelled extraction should be cleaned up and its window closed");

    NAAssertFalse(wc.window.isVisible, @"window should close after cleanup");
    NAAssertFalse([self fileExists:@"test" under:dir],
                  @"closing during extraction should remove the output");
}


#pragma mark - Quarantine

- (void)testExtractedFilesInheritQuarantine {
    NSString *dir = [self makeUnwrapDestination];
    NSString *archive = [self copyFixture:@"test.zip" to:@"test.zip" under:dir];
    const char *value = "0083;00000000;N2OArchiverTests;";
    setxattr(archive.fileSystemRepresentation, "com.apple.quarantine",
             value, strlen(value), 0, 0);

    NAExtractionWindowController *wc =
        [[NAExtractionWindowController alloc] initWithArchivePath:archive];
    [wc beginExtraction];
    NAAssertTrue(NAWaitUntil(^BOOL { return !wc.isWorking; }, 10.0),
                 @"extraction should finish");

    NSString *dest = [dir stringByAppendingPathComponent:@"test"];
    NSString *extracted = nil;
    for (NSString *item in [[NSFileManager defaultManager] enumeratorAtPath:dest]) {
        if ([item.lastPathComponent isEqualToString:@"a.txt"]) {
            extracted = [dest stringByAppendingPathComponent:item];
        }
    }
    NAAssertNotNil(extracted, @"a.txt should be extracted under %@", dest);

    char buffer[256];
    ssize_t length = getxattr(extracted.fileSystemRepresentation, "com.apple.quarantine",
                              buffer, sizeof(buffer), 0, XATTR_NOFOLLOW);
    NSString *copied = length > 0
        ? [[NSString alloc] initWithBytes:buffer length:length encoding:NSUTF8StringEncoding]
        : nil;
    NAAssertEqualObjects(copied, @(value),
                         @"extracted file should carry the archive's quarantine value, got %@",
                         copied);
}

#pragma mark - Process activity

- (void)testWorkingControllerHoldsProcessActivity {
    NSString *dir = [self makeUnwrapDestination];
    NSString *archive = [self copyFixture:@"test.zip" to:@"test.zip" under:dir];
    NAExtractionWindowController *wc =
        [[NAExtractionWindowController alloc] initWithArchivePath:archive];

    [wc beginExtraction];
    NAAssertNotNil([wc valueForKey:@"activity"],
                   @"extraction should hold an NSProcessInfo activity");

    NAAssertTrue(NAWaitUntil(^BOOL { return !wc.isWorking; }, 10.0),
                 @"extraction should finish");
    NAAssertNil([wc valueForKey:@"activity"],
                @"the activity should end when the work is finished");
}

#pragma mark - Error presentation

- (void)testErrorIsPresentedAsSheetWithDetails {
    NSString *dir = [self makeUnwrapDestination];
    NSString *archive = [self copyFixture:@"corrupt.zip" to:@"broken.zip" under:dir];
    NAExtractionWindowController *wc =
        [[NAExtractionWindowController alloc] initWithArchivePath:archive];

    [wc beginExtraction];
    NAAssertTrue(NAWaitUntil(^BOOL { return !wc.isWorking && wc.window.attachedSheet != nil; }, 10.0),
                 @"the error should be presented as a sheet on the extraction window");

    NSError *shown = [wc valueForKey:@"presentedError"];
    NAAssertTrue([shown.localizedDescription containsString:@"“broken.zip” could not be extracted"],
                 @"the sheet title should name the archive, got %@", shown.localizedDescription);
    NAAssertTrue([shown.localizedRecoverySuggestion containsString:@"Unrecognized archive format"],
                 @"the sheet should show the extractor's message in full, got %@",
                 shown.localizedRecoverySuggestion);

    [wc.window endSheet:wc.window.attachedSheet returnCode:NSAlertFirstButtonReturn];
    NAAssertTrue(NAWaitUntil(^BOOL { return !wc.window.isVisible; }, 10.0),
                 @"dismissing the error should close the window");    NAAssertFalse([self fileExists:@"broken" under:dir],
                  @"a failed extraction that wrote nothing should leave no folder");
    NAAssertEqual([self stagingDirectoriesIn:dir].count, 0u, @"no staging directory should remain");
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

    NAAssertTrue(NAWaitUntil(^BOOL { return !wc.isWorking; }, 10.0),
                 @"extraction should finish");

    // Window should still exist (not auto-closed on error).
    NSButton *button = [wc valueForKey:@"cancelButton"];
    NSTextField *status = [wc valueForKey:@"statusLabel"];
    NAAssertTrue([button.title isEqualToString:@"Close"],
                 @"the button should offer Close after an error, got %@", button.title);
    NAAssertTrue(status.stringValue.length > 0 &&
                 ![status.stringValue isEqualToString:@"Extracting…"],
                 @"the status should show the error, got %@", status.stringValue);
    if (wc.window.attachedSheet) {
        [wc.window endSheet:wc.window.attachedSheet returnCode:NSAlertFirstButtonReturn];
    }
}

@end
