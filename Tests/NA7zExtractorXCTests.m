#import <XCTest/XCTest.h>
#import "NATestFixtures.h"
#import "Plugins/NA7zExtractor.h"
#import "Plugins/NA7zzTool.h"

@interface NA7zExtractorXCTests : XCTestCase
@property (nonatomic, strong) NA7zExtractor *extractor;
@property (nonatomic, copy) NSString *destDir;
@end

@implementation NA7zExtractorXCTests

+ (void)setUp {
    [NATestFixtures setUp];
}

+ (void)tearDown {
    [NATestFixtures tearDown];
}

- (void)setUp {
    [super setUp];
    self.extractor = [[NA7zExtractor alloc] init];
    self.destDir = [NSTemporaryDirectory()
        stringByAppendingPathComponent:
            [NSString stringWithFormat:@"n2o-7z-test-%u", arc4random()]];
    [[NSFileManager defaultManager] createDirectoryAtPath:self.destDir
                              withIntermediateDirectories:YES
                                               attributes:nil error:nil];
}

- (void)tearDown {
    [[NSFileManager defaultManager] removeItemAtPath:self.destDir error:nil];
    [super tearDown];
}

#pragma mark - Tool availability

- (void)testToolPathFound {
    XCTAssertNotNil([NA7zzTool toolPath]);
}

#pragma mark - Extraction

- (void)testExtract7z {
    NSString *path = [NATestFixtures pathForFixture:@"test.7z"];
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:path]);

    NSError *error = nil;
    BOOL ok = [self.extractor extractArchiveAtPath:path
                                      toDestination:self.destDir
                                           progress:nil
                                              error:&error];
    XCTAssertTrue(ok, @"%@", error.localizedDescription);

    NSString *aPath = [self findFileNamed:@"a.txt" under:self.destDir];
    XCTAssertNotNil(aPath);

    NSString *contents = [NSString stringWithContentsOfFile:aPath
                                                   encoding:NSUTF8StringEncoding
                                                      error:nil];
    XCTAssertEqualObjects(contents, @"file-a contents\n");
}

#pragma mark - Contents listing

- (void)testListContents {
    NSString *path = [NATestFixtures pathForFixture:@"test.7z"];
    NSError *error = nil;
    NSArray<NSString *> *entries = [self.extractor contentsOfArchiveAtPath:path
                                                                    error:&error];
    XCTAssertNil(error);
    XCTAssertNotNil(entries);
    XCTAssertGreaterThanOrEqual(entries.count, 3u);
}

#pragma mark - canHandleFile

- (void)testCanHandle7z {
    XCTAssertTrue([NA7zExtractor canHandleFileAtPath:
                   [NATestFixtures pathForFixture:@"test.7z"]]);
}

- (void)testCanHandleRejectsZip {
    XCTAssertFalse([NA7zExtractor canHandleFileAtPath:
                    [NATestFixtures pathForFixture:@"test.zip"]]);
}

- (void)testCanHandleRejectsMissing {
    XCTAssertFalse([NA7zExtractor canHandleFileAtPath:@"/nonexistent/file.7z"]);
}

#pragma mark - Supported extensions

- (void)testSupportedExtensions {
    NSArray<NSString *> *exts = [NA7zExtractor supportedExtensions];
    XCTAssertGreaterThan(exts.count, 0u);
    XCTAssertTrue([exts containsObject:@"7z"]);
}

#pragma mark - Progress

- (void)testProgressReachesCompletion {
    __block NSUInteger calls = 0;
    __block double lastFraction = -1;
    NSError *error = nil;
    BOOL ok = [self.extractor extractArchiveAtPath:[NATestFixtures pathForFixture:@"test.7z"]
                                     toDestination:self.destDir
                                          progress:^(double fraction, NSString *entry) {
        calls++;
        lastFraction = fraction;
    }
                                             error:&error];
    XCTAssertTrue(ok, @"extraction should succeed: %@", error.localizedDescription);
    XCTAssertTrue(calls > 0, @"progress should be reported");
    XCTAssertTrue(lastFraction == 1.0, @"last progress should be 1.0, got %f", lastFraction);
}

- (void)testProgressParserHandlesSplitStatusStrings {
    NSMutableArray<NSNumber *> *fractions = [NSMutableArray array];
    NSMutableArray<NSString *> *entries = [NSMutableArray array];
    NA7zzProgressParser *parser =
        [[NA7zzProgressParser alloc] initWithHandler:^(double fraction, NSString *entry) {
        [fractions addObject:@(fraction)];
        [entries addObject:entry];
    }];

    // Shape of `7zz x -bsp1` output: header lines, then status strings
    // separated by backspaces, with a run of spaces that erases the previous one.
    const char raw[] =
        "Path = big.7z\nSolid = -\n\n  0%\b\b\b\b    \b\b\b\b"
        "  3% 1 - src/big.bin\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b"
        " 97% 1 - src/big.bin\b\b\b\n\nEverything is Ok\n";
    NSData *data = [NSData dataWithBytes:raw length:strlen(raw)];

    // Feed 7 bytes at a time so status strings are split across calls.
    for (NSUInteger i = 0; i < data.length; i += 7) {
        [parser appendData:[data subdataWithRange:
            NSMakeRange(i, MIN((NSUInteger)7, data.length - i))]];
    }

    XCTAssertEqualObjects(fractions, (@[@0.0, @0.03, @0.97]),
                         @"fractions should be 0, 0.03, 0.97, got %@", fractions);
    XCTAssertEqualObjects(entries, (@[@"", @"big.bin", @"big.bin"]),
                         @"entries should carry the file name, got %@", entries);
}

- (void)testListContentsExcludesArchivePath {
    NSString *path = [NATestFixtures pathForFixture:@"test.7z"];
    NSError *error = nil;
    NSArray<NSString *> *entries = [self.extractor contentsOfArchiveAtPath:path error:&error];
    NSSet *expected = [NSSet setWithObjects:@"src", @"src/subdir", @"src/a.txt", @"src/b.txt", @"src/subdir/c.txt", nil];
    XCTAssertEqualObjects([NSSet setWithArray:entries], expected,
                         @"entries should be the archive members only, got %@ (%@)",
                         entries, error);
}

- (void)testExtractRelativePathStartingWithDash {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *workDir = [self.destDir stringByAppendingPathComponent:@"work"];
    NSString *outDir = [self.destDir stringByAppendingPathComponent:@"out"];
    [fm createDirectoryAtPath:workDir withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:outDir withIntermediateDirectories:YES attributes:nil error:nil];
    [fm copyItemAtPath:[NATestFixtures pathForFixture:@"test.7z"]
                toPath:[workDir stringByAppendingPathComponent:@"-test.7z"] error:nil];

    // 7zz reads an argument starting with "-" as a switch unless it follows "--".
    NSString *previousDir = fm.currentDirectoryPath;
    [fm changeCurrentDirectoryPath:workDir];
    NSError *error = nil;
    BOOL ok = [self.extractor extractArchiveAtPath:@"-test.7z"
                                     toDestination:outDir
                                          progress:nil
                                             error:&error];
    [fm changeCurrentDirectoryPath:previousDir];

    XCTAssertTrue(ok, @"archive path starting with - should extract: %@",
                 error.localizedDescription);
}

- (void)testEncryptedArchiveFailsWithPasswordError {
    NSString *path = [NATestFixtures pathForFixture:@"encrypted.7z"];
    NA7zExtractor *extractor = self.extractor;
    NSString *dest = self.destDir;
    __block BOOL ok = YES;
    __block NSError *error = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *e = nil;
        ok = [extractor extractArchiveAtPath:path toDestination:dest progress:nil error:&e];
        error = e;
        dispatch_semaphore_signal(done);
    });
    long timedOut = dispatch_semaphore_wait(done,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)));
    if (timedOut) [extractor cancelExtraction];

    XCTAssertFalse(timedOut, @"extraction should not wait for a password");
    XCTAssertFalse(ok, @"encrypted archive should fail");
    XCTAssertTrue([error.localizedDescription containsString:@"password-protected"],
                 @"error should say the archive is password-protected, got %@",
                 error.localizedDescription);
    XCTAssertTrue(error.localizedRecoverySuggestion.length > 0,
                 @"the password error should say what the user can do");
}

- (void)testListEncryptedArchiveFailsWithPasswordError {
    NSError *error = nil;
    NSArray *entries = [self.extractor contentsOfArchiveAtPath:
        [NATestFixtures pathForFixture:@"encrypted.7z"] error:&error];
    XCTAssertNil(entries, @"listing an encrypted archive should fail");
    XCTAssertTrue([error.localizedDescription containsString:@"password-protected"],
                 @"error should say the archive is password-protected, got %@",
                 error.localizedDescription);
}

- (void)testToolFailureKeepsStandardErrorAsFailureReason {
    NSError *error = nil;
    BOOL ok = [self.extractor extractArchiveAtPath:@"/nonexistent/file.7z"
                                     toDestination:self.destDir
                                          progress:nil
                                             error:&error];
    XCTAssertFalse(ok, @"a missing archive should fail");
    XCTAssertEqualObjects(error.localizedDescription, @"7zz could not extract the archive.",
                         @"the description should be a short summary, got %@",
                         error.localizedDescription);
    XCTAssertTrue(error.localizedFailureReason.length > 0,
                 @"7zz stderr should be kept as the failure reason");
}

#pragma mark - Cancellation

- (void)testCancelBeforeExtractionReturnsCancelled {
    [self.extractor cancelExtraction];
    NSError *error = nil;
    BOOL ok = [self.extractor extractArchiveAtPath:[NATestFixtures pathForFixture:@"test.7z"]
                                     toDestination:self.destDir
                                          progress:nil
                                             error:&error];
    XCTAssertFalse(ok, @"cancelled extraction should return NO");
    XCTAssertTrue([error.domain isEqualToString:NSCocoaErrorDomain] &&
                 error.code == NSUserCancelledError,
                 @"error should be NSUserCancelledError, got %@", error);
    XCTAssertEqual([[NSFileManager defaultManager]
                      contentsOfDirectoryAtPath:self.destDir error:nil].count, 0u,
                  @"nothing should be extracted");
}

#pragma mark - Error handling

- (void)testExtractMissingFileFails {
    NSError *error = nil;
    BOOL ok = [self.extractor extractArchiveAtPath:@"/nonexistent/file.7z"
                                      toDestination:self.destDir
                                           progress:nil
                                              error:&error];
    XCTAssertFalse(ok);
    XCTAssertNotNil(error);
}

#pragma mark - Helpers

- (NSString *)findFileNamed:(NSString *)name under:(NSString *)dir {
    NSDirectoryEnumerator *enumerator =
        [[NSFileManager defaultManager] enumeratorAtPath:dir];
    NSString *item;
    while ((item = [enumerator nextObject])) {
        if ([item.lastPathComponent isEqualToString:name]) {
            return [dir stringByAppendingPathComponent:item];
        }
    }
    return nil;
}

@end
