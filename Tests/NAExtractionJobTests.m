#import "NATestCase.h"
#import "NATestFixtures.h"
#import "NATestScriptedExtractor.h"
#import "NAWait.h"
#import "NAExtractionJob.h"
#include <sys/stat.h>
#include <sys/xattr.h>

// Private methods under test.
@interface NAExtractionJob (Testing)
- (NSURL *)moveStagingDirectory:(NSURL *)stagingURL
        toDestinationForArchive:(NSURL *)archiveURL
                          error:(NSError **)error;
- (void)unwrapSingleItemDirectoryAtURL:(NSURL *)destinationURL;
@end

@interface NAExtractionJobTests : NATestCase
@property (nonatomic, copy) NSString *workDir;
@property (nonatomic, strong) NAPluginManager *pluginManager;
@end

@implementation NAExtractionJobTests

static const char *const kQuarantineValue = "0083;00000000;N2OArchiverTests;";

- (void)setUp {
    [super setUp];
    self.workDir = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"n2o-job-%u", arc4random()]];
    [[NSFileManager defaultManager] createDirectoryAtPath:self.workDir
                              withIntermediateDirectories:YES
                                               attributes:nil error:nil];
    // A fresh manager, so routing does not depend on other suites.
    self.pluginManager = [[NAPluginManager alloc] init];
    [self.pluginManager registerBuiltinExtractors];
    [self.pluginManager registerExtractorClass:[NATestScriptedExtractor class]];
    NAScriptedRelease = dispatch_semaphore_create(0);
}

- (void)tearDown {
    // Clear flags and restore owner access left by tests.
    for (NSString *item in [[NSFileManager defaultManager] enumeratorAtPath:self.workDir]) {
        const char *path = [self.workDir stringByAppendingPathComponent:item].fileSystemRepresentation;
        struct stat st;
        if (lstat(path, &st) == 0 && !S_ISLNK(st.st_mode)) {
            chflags(path, 0);
            chmod(path, (st.st_mode & 0777) | (S_ISDIR(st.st_mode) ? 0700 : 0600));
        }
    }
    [[NSFileManager defaultManager] removeItemAtPath:self.workDir error:nil];
    [super tearDown];
}

#pragma mark - Outcomes

- (void)testSucceedsAndMovesOutputIntoPlace {
    NSString *archive = [self copyFixture:@"test.zip" to:@"test.zip"];
    NAExtractionJob *job = [self jobForArchive:archive];
    [job start];

    NAAssertTrue([self waitForJob:job], @"the job should finish");
    NAAssertEqual(job.state, NAExtractionJobStateSucceeded, @"the job should succeed: %@", job.error);
    NAAssertEqualObjects(job.destinationURL.path, [self.workDir stringByAppendingPathComponent:@"test"],
                         @"the output should be named after the archive");
    NAAssertTrue([self fileExists:@"test/a.txt"], @"the single top-level folder should be unwrapped");
    NAAssertEqual([self stagingDirectories].count, 0u, @"no staging directory should remain");
}

- (void)testUnrecognizedFileFails {
    [self writeFile:@"notes.txt"];
    NAExtractionJob *job = [self jobForArchive:[self.workDir stringByAppendingPathComponent:@"notes.txt"]];
    [job start];

    NAAssertEqual(job.state, NAExtractionJobStateFailed, @"a file no extractor handles should fail");
    NAAssertTrue([job.error.localizedDescription containsString:@"does not recognize"],
                 @"the error should say the format is not recognized, got %@", job.error);
    NAAssertEqual([self stagingDirectories].count, 0u, @"no staging directory should be created");
}

- (void)testCompletionHandlerRunsOnceOnMainThread {
    NSString *archive = [self copyFixture:@"test.zip" to:@"test.zip"];
    NAExtractionJob *job = [self jobForArchive:archive];
    __block NSUInteger calls = 0;
    __block BOOL onMainThread = NO;
    job.completionHandler = ^(NAExtractionJob *finished) {
        calls++;
        onMainThread = [NSThread isMainThread];
    };
    [job start];
    NAAssertTrue([self waitForJob:job], @"the job should finish");
    [job cancel];
    NAWaitUntil(^BOOL { return NO; }, 0.2);

    NAAssertEqual(calls, 1u, @"the completion handler should run once");
    NAAssertTrue(onMainThread, @"the completion handler should run on the main thread");
}

- (void)testProgressHandlerReceivesExtractorProgress {
    NSString *archive = [self writeFile:@"wait-progress.n2oscripted"];
    NAExtractionJob *job = [self jobForArchive:archive];
    __block double lastFraction = -1;
    __block NSString *lastEntry = nil;
    job.progressHandler = ^(double fraction, NSString *entry) {
        lastFraction = fraction;
        lastEntry = entry;
    };
    [job start];

    NAAssertTrue(NAWaitUntil(^BOOL { return lastFraction == 0.5; }, 10.0),
                 @"the extractor's 50%% should reach the progress handler, got %f", lastFraction);
    NAAssertEqualObjects(lastEntry, @"payload.txt", @"the entry should be the progress's fileURL name");
    dispatch_semaphore_signal(NAScriptedRelease);
    NAAssertTrue([self waitForJob:job], @"the job should finish");
}

#pragma mark - Staging directory

- (void)testOutputIsExtractedIntoHiddenStagingDirectory {
    NSString *archive = [self writeFile:@"wait.n2oscripted"];
    setxattr(archive.fileSystemRepresentation, "com.apple.quarantine",
             kQuarantineValue, strlen(kQuarantineValue), 0, 0);
    NAExtractionJob *job = [self jobForArchive:archive];
    [job start];

    NAAssertTrue(NAWaitUntil(^BOOL {
        for (NSString *staging in [self stagingDirectories]) {
            if ([self fileExists:[staging stringByAppendingPathComponent:@"payload.txt"]]) return YES;
        }
        return NO;
    }, 10.0), @"files should be written into a hidden .n2o-extract- directory");
    NAAssertFalse([self fileExists:@"wait"],
                  @"the visible output folder should not exist while extracting");
    NAAssertTrue(job.isActive, @"the job should be active while extracting");

    dispatch_semaphore_signal(NAScriptedRelease);
    NAAssertTrue([self waitForJob:job], @"the job should finish");

    NAAssertTrue([self fileExists:@"wait/payload.txt"],
                 @"the staging directory should be renamed to the archive's base name");
    NAAssertEqual([self stagingDirectories].count, 0u, @"no staging directory should remain");
    NAAssertEqualObjects([self quarantineAt:@"wait/payload.txt"], @(kQuarantineValue),
                         @"the file should be quarantined before it gets its visible name");
}

- (void)testFailedExtractionRemovesPartialOutput {
    NSString *archive = [self writeFile:@"fail-partial.n2oscripted"];
    NAExtractionJob *job = [self jobForArchive:archive];
    [job start];

    NAAssertTrue([self waitForJob:job], @"the job should finish");
    NAAssertEqual(job.state, NAExtractionJobStateFailed, @"the job should fail");
    NAAssertNil(job.destinationURL, @"no output should be moved into place");
    NAAssertFalse([self fileExists:@"fail-partial"], @"a failed extraction should leave no output folder");
    NAAssertEqual([self stagingDirectories].count, 0u,
                  @"the partial output in the staging directory should be removed");
}

- (void)testFailedExtractionAlsoReportsQuarantineFailure {
    NSString *archive = [self writeFile:@"immutable.n2oscripted"];
    setxattr(archive.fileSystemRepresentation, "com.apple.quarantine",
             kQuarantineValue, strlen(kQuarantineValue), 0, 0);
    NAExtractionJob *job = [self jobForArchive:archive];
    [job start];

    NAAssertTrue([self waitForJob:job], @"the job should finish");
    NAAssertEqual(job.state, NAExtractionJobStateFailed, @"the job should fail");
    NSString *suggestion = job.error.localizedRecoverySuggestion;
    NAAssertTrue([job.error.localizedDescription containsString:@"Scripted extraction failure."],
                 @"the extraction error should be reported, got %@", job.error);
    NAAssertTrue([suggestion containsString:@"could not be marked as downloaded"],
                 @"the quarantine failure should also be reported, got %@", suggestion);
    NAAssertTrue([suggestion containsString:@"could not be removed"],
                 @"the immutable leftover should be reported, got %@", suggestion);
}

#pragma mark - Quarantine

- (void)testExtractedFilesInheritQuarantine {
    NSString *archive = [self copyFixture:@"test.zip" to:@"test.zip"];
    setxattr(archive.fileSystemRepresentation, "com.apple.quarantine",
             kQuarantineValue, strlen(kQuarantineValue), 0, 0);
    NAExtractionJob *job = [self jobForArchive:archive];
    [job start];

    NAAssertTrue([self waitForJob:job], @"the job should finish");
    NAAssertEqualObjects([self quarantineAt:@"test/a.txt"], @(kQuarantineValue),
                         @"extracted files should carry the archive's quarantine value");
}

#pragma mark - Process activity

- (void)testActiveJobHoldsProcessActivity {
    NSString *archive = [self writeFile:@"wait.n2oscripted"];
    NAExtractionJob *job = [self jobForArchive:archive];
    [job start];

    NAAssertNotNil([job valueForKey:@"activity"], @"an active job should hold an NSProcessInfo activity");
    dispatch_semaphore_signal(NAScriptedRelease);
    NAAssertTrue([self waitForJob:job], @"the job should finish");
    NAAssertNil([job valueForKey:@"activity"], @"the activity should end when the job finishes");
}

#pragma mark - Free space

- (void)testFreeSpaceThresholdIsSmallerOfOneGigabyteAndFivePercent {
    const uint64_t GB = 1000ull * 1000 * 1000;
    NAAssertFalse([NAExtractionJob isFreeSpaceLowWithAvailable:2 * GB total:500 * GB],
                  @"2 GB free on a 500 GB volume is enough");
    NAAssertTrue([NAExtractionJob isFreeSpaceLowWithAvailable:GB / 10 * 9 total:500 * GB],
                 @"under 1 GB free on a large volume is low");
    NAAssertFalse([NAExtractionJob isFreeSpaceLowWithAvailable:GB / 10 * 6 total:10 * GB],
                  @"600 MB free on a 10 GB volume is above 5%%");
    NAAssertTrue([NAExtractionJob isFreeSpaceLowWithAvailable:GB / 10 * 4 total:10 * GB],
                 @"400 MB free on a 10 GB volume is below 5%%");
}

- (void)testStopsWhenFreeSpaceRunsLow {
    NSString *archive = [self writeFile:@"wait-space.n2oscripted"];
    NAExtractionJob *job = [self jobForArchive:archive];
    __block BOOL low = NO;
    job.spaceIsLow = ^BOOL(NSURL *url) { return low; };
    [job start];

    NAAssertTrue(NAWaitUntil(^BOOL { return [self stagingDirectories].count == 1; }, 10.0),
                 @"extraction should start");
    low = YES;
    NAAssertTrue(NAWaitUntil(^BOOL { return job.state == NAExtractionJobStateCancelling; }, 10.0),
                 @"low free space should stop the extraction");
    dispatch_semaphore_signal(NAScriptedRelease);

    NAAssertTrue([self waitForJob:job], @"the job should finish");
    NAAssertEqual(job.state, NAExtractionJobStateCancelled, @"the job should end cancelled");
    NAAssertTrue([job.error.localizedRecoverySuggestion containsString:@"almost full"],
                 @"the error should say the disk is almost full, got %@", job.error);
    NAAssertFalse([self fileExists:@"wait-space"], @"no output folder should remain");
    NAAssertEqual([self stagingDirectories].count, 0u, @"the staging directory should be removed");
}

#pragma mark - Cancellation

- (void)testCancelBeforeStartFinishesCancelled {
    NSString *archive = [self copyFixture:@"test.zip" to:@"test.zip"];
    NAExtractionJob *job = [self jobForArchive:archive];
    __block NSUInteger calls = 0;
    job.completionHandler = ^(NAExtractionJob *finished) { calls++; };

    [job cancel];
    [job start];

    NAAssertEqual(job.state, NAExtractionJobStateCancelled, @"a pending job should cancel at once");
    NAAssertEqual(calls, 1u, @"the completion handler should run once");
    NAAssertNil(job.error, @"a cancel requested by the caller has no error");
    NAAssertEqual([self stagingDirectories].count, 0u, @"start after cancel should do nothing");
}

- (void)testCancelAfterFinishHasNoEffect {
    NSString *archive = [self copyFixture:@"test.zip" to:@"test.zip"];
    NAExtractionJob *job = [self jobForArchive:archive];
    [job start];
    NAAssertTrue([self waitForJob:job], @"the job should finish");

    [job cancel];

    NAAssertEqual(job.state, NAExtractionJobStateSucceeded, @"a finished job should keep its state");
    NAAssertTrue([self fileExists:@"test/a.txt"], @"the output should remain");
}

- (void)testExtractorErrorWhileCancellingEndsCancelled {
    NSString *archive = [self writeFile:@"cancel-fail.n2oscripted"];
    NAExtractionJob *job = [self jobForArchive:archive];
    [job start];
    NAAssertTrue(NAWaitUntil(^BOOL { return [self stagingDirectories].count == 1; }, 10.0),
                 @"extraction should start");

    [job cancel];
    NAAssertEqual(job.state, NAExtractionJobStateCancelling, @"cancel should move to cancelling");
    NAAssertTrue(job.isActive, @"a cancelling job is still active");
    dispatch_semaphore_signal(NAScriptedRelease);

    NAAssertTrue([self waitForJob:job], @"the job should finish");
    NAAssertEqual(job.state, NAExtractionJobStateCancelled,
                  @"an extractor error after cancel should still end cancelled");
    NAAssertNil(job.error, @"the extractor's error should not be reported for a cancel");
    NAAssertEqual([self stagingDirectories].count, 0u, @"the staging directory should be removed");
    NAAssertFalse([self fileExists:@"cancel-fail"], @"no output folder should remain");
}

- (void)testCancelIsPassedToExtractorThroughProgress {
    NSString *archive = [self writeFile:@"wait-cancel.n2oscripted"];
    NAExtractionJob *job = [self jobForArchive:archive];
    [job start];
    NAAssertTrue(NAWaitUntil(^BOOL { return [self stagingDirectories].count == 1; }, 10.0),
                 @"extraction should start");

    [job cancel];

    // NAScriptedRelease is not signalled: the extractor returns only because
    // its progress was cancelled.
    NAAssertTrue([self waitForJob:job], @"the extractor should stop when the job is cancelled");
    NAAssertEqual(job.state, NAExtractionJobStateCancelled, @"the job should end cancelled");
    NAAssertEqual([self stagingDirectories].count, 0u, @"the staging directory should be removed");
}

- (void)testCancelKeepsExistingDirectory {
    NSString *archive = [self copyFixture:@"test.zip" to:@"test.zip"];
    [self writeFile:@"test/keep.txt"];
    NAExtractionJob *job = [self jobForArchive:archive];
    [job start];
    [job cancel];

    NAAssertTrue([self waitForJob:job], @"the job should finish");
    NAAssertTrue([self fileExists:@"test/keep.txt"],
                 @"cancel should not remove a directory that existed before extraction");
    NAAssertFalse([self fileExists:@"test 2"], @"cancel should leave no output folder");
    NAAssertEqual([self stagingDirectories].count, 0u, @"cancel should remove the staging directory");
}

#pragma mark - Destination directory

- (void)testDestinationUsesArchiveBaseName {
    NSString *archive = [self copyFixture:@"test.zip" to:@"test.zip"];
    [self writeFile:@".n2o-extract-staging/a.txt"];

    NSError *error = nil;
    NSURL *dest = [[self jobForArchive:archive]
        moveStagingDirectory:[self workURL:@".n2o-extract-staging"]
     toDestinationForArchive:NAFileURL(archive)
                       error:&error];

    NAAssertEqualObjects(dest.path, [self.workDir stringByAppendingPathComponent:@"test"],
                         @"destination should be the archive base name, got %@ (%@)", dest, error);
    NAAssertTrue([self fileExists:@"test/a.txt"], @"staging contents should move");
    NAAssertFalse([self fileExists:@".n2o-extract-staging"], @"staging should be gone");
}

- (void)testDestinationSkipsExistingDirectory {
    NSString *archive = [self copyFixture:@"test.zip" to:@"test.zip"];
    [self writeFile:@"test/keep.txt"];
    [self writeFile:@".n2o-extract-staging/a.txt"];

    NSURL *dest = [[self jobForArchive:archive]
        moveStagingDirectory:[self workURL:@".n2o-extract-staging"]
     toDestinationForArchive:NAFileURL(archive)
                       error:nil];

    NAAssertEqualObjects(dest.path, [self.workDir stringByAppendingPathComponent:@"test 2"],
                         @"existing directory should not be replaced, got %@", dest);
    NAAssertEqual([[NSFileManager defaultManager]
                      contentsOfDirectoryAtPath:[self.workDir stringByAppendingPathComponent:@"test"]
                                          error:nil].count, 1u,
                  @"existing directory should be unchanged");
}

- (void)testDestinationSkipsArchiveWithoutExtension {
    NSString *archive = [self copyFixture:@"test.zip" to:@"mystery"];
    [self writeFile:@".n2o-extract-staging/a.txt"];

    NSURL *dest = [[self jobForArchive:archive]
        moveStagingDirectory:[self workURL:@".n2o-extract-staging"]
     toDestinationForArchive:NAFileURL(archive)
                       error:nil];

    NAAssertEqualObjects(dest.path, [self.workDir stringByAppendingPathComponent:@"mystery 2"],
                         @"archive file itself should not be replaced, got %@", dest);
}

#pragma mark - Unwrapping a single top-level directory

- (void)testUnwrapMovesDirectoryContentsUp {
    NSString *dest = [self directory:@"unwrap"];
    [self writeFile:@"unwrap/inner/a.txt"];
    [self writeFile:@"unwrap/inner/sub/b.txt"];

    [[self unwrapJob] unwrapSingleItemDirectoryAtURL:NAFileURL(dest)];

    NAAssertTrue([self fileExists:@"unwrap/a.txt"], @"a.txt should move up");
    NAAssertTrue([self fileExists:@"unwrap/sub/b.txt"], @"sub/b.txt should move up");
    NAAssertFalse([self fileExists:@"unwrap/inner"], @"inner should be removed");
}

- (void)testUnwrapChildWithSameNameAsDirectory {
    NSString *dest = [self directory:@"unwrap"];
    [self writeFile:@"unwrap/x/x/important.txt"];

    [[self unwrapJob] unwrapSingleItemDirectoryAtURL:NAFileURL(dest)];

    NAAssertTrue([self fileExists:@"unwrap/x/important.txt"],
                 @"x/x/important.txt should become x/important.txt");
}

- (void)testUnwrapIgnoresSymlinkToDirectory {
    [self writeFile:@"outside/keep.txt"];
    NSString *out = [self directory:@"out"];
    [[NSFileManager defaultManager]
        createSymbolicLinkAtPath:[out stringByAppendingPathComponent:@"link"]
             withDestinationPath:[self.workDir stringByAppendingPathComponent:@"outside"]
                           error:nil];

    [[self unwrapJob] unwrapSingleItemDirectoryAtURL:NAFileURL(out)];

    NAAssertTrue([self fileExists:@"outside/keep.txt"],
                 @"files in the symlinked directory should not be moved");
    NAAssertFalse([self fileExists:@"out/keep.txt"],
                  @"symlinked directory contents should not appear in the destination");
}

- (void)testUnwrapSkippedWhenHiddenItemPresent {
    NSString *dest = [self directory:@"unwrap"];
    [self writeFile:@"unwrap/.hidden"];
    [self writeFile:@"unwrap/dir/.hidden"];

    [[self unwrapJob] unwrapSingleItemDirectoryAtURL:NAFileURL(dest)];

    NAAssertTrue([self fileExists:@"unwrap/.hidden"], @"top-level .hidden should remain");
    NAAssertTrue([self fileExists:@"unwrap/dir/.hidden"], @"dir/.hidden should remain");
}

- (void)testUnwrapRestoresLayoutWhenMoveFails {
    NSString *dest = [self directory:@"unwrap"];
    [self writeFile:@"unwrap/.DS_Store"];
    [self writeFile:@"unwrap/inner/.DS_Store"];
    [self writeFile:@"unwrap/inner/a.txt"];

    [[self unwrapJob] unwrapSingleItemDirectoryAtURL:NAFileURL(dest)];

    NAAssertTrue([self fileExists:@"unwrap/inner/.DS_Store"], @"inner/.DS_Store should be restored");
    NAAssertTrue([self fileExists:@"unwrap/inner/a.txt"], @"inner/a.txt should be restored");
    NAAssertEqual([[NSFileManager defaultManager] contentsOfDirectoryAtPath:dest error:nil].count, 2u,
                  @"destination should contain only .DS_Store and inner");
}

#pragma mark - Helpers

- (NAExtractionJob *)jobForArchive:(NSString *)archivePath {
    return [[NAExtractionJob alloc] initWithArchiveURL:NAFileURL(archivePath) pluginManager:self.pluginManager];
}

- (NAExtractionJob *)unwrapJob {
    return [self jobForArchive:[self.workDir stringByAppendingPathComponent:@"unused.zip"]];
}

- (BOOL)waitForJob:(NAExtractionJob *)job {
    return NAWaitUntil(^BOOL { return job.state >= NAExtractionJobStateSucceeded; }, 10.0);
}

- (NSString *)copyFixture:(NSString *)fixture to:(NSString *)name {
    NSString *path = [self.workDir stringByAppendingPathComponent:name];
    [[NSFileManager defaultManager] copyItemAtPath:[NATestFixtures pathForFixture:fixture]
                                            toPath:path error:nil];
    return path;
}

- (NSString *)writeFile:(NSString *)relativePath {
    NSString *path = [self.workDir stringByAppendingPathComponent:relativePath];
    [[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent
                              withIntermediateDirectories:YES attributes:nil error:nil];
    [relativePath writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
    return path;
}

// A URL under the test's working directory.
- (NSURL *)workURL:(NSString *)relativePath {
    return NAFileURL([self.workDir stringByAppendingPathComponent:relativePath]);
}

- (NSString *)directory:(NSString *)relativePath {
    NSString *path = [self.workDir stringByAppendingPathComponent:relativePath];
    [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES
                                               attributes:nil error:nil];
    return path;
}

- (BOOL)fileExists:(NSString *)relativePath {
    return [[NSFileManager defaultManager] fileExistsAtPath:
        [self.workDir stringByAppendingPathComponent:relativePath]];
}

- (NSArray<NSString *> *)stagingDirectories {
    NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:self.workDir error:nil];
    return [items filteredArrayUsingPredicate:
        [NSPredicate predicateWithFormat:@"SELF BEGINSWITH '.n2o-extract-'"]];
}

- (NSString *)quarantineAt:(NSString *)relativePath {
    char buffer[256];
    ssize_t length = getxattr([self.workDir stringByAppendingPathComponent:relativePath].fileSystemRepresentation,
                              "com.apple.quarantine", buffer, sizeof(buffer), 0, XATTR_NOFOLLOW);
    if (length <= 0) return nil;
    return [[NSString alloc] initWithBytes:buffer length:(NSUInteger)length encoding:NSUTF8StringEncoding];
}

@end
