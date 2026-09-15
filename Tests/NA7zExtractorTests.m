#import "NATestCase.h"
#import "NATestFixtures.h"
#import "NAPluginManager.h"
#import "Plugins/NA7zExtractor.h"
#import "Plugins/NA7zzTool.h"

@interface NA7zExtractorTests : NATestCase
@property (nonatomic, strong) NA7zExtractor *extractor;
@property (nonatomic, copy) NSString *destDir;
@end

@implementation NA7zExtractorTests

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
    NAAssertNotNil([NA7zzTool toolPath], @"7zz should be found on this system");
}

#pragma mark - Extraction

- (void)testExtract7z {
    NSString *path = [NATestFixtures pathForFixture:@"test.7z"];
    NAAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:path],
                 @"test.7z fixture should exist");

    NSError *error = nil;
    BOOL ok = [self.extractor extractArchiveAtPath:path
                                      toDestination:self.destDir
                                           progress:nil
                                              error:&error];
    NAAssertTrue(ok, @"7z extraction should succeed: %@", error.localizedDescription);

    NSString *aPath = [self findFileNamed:@"a.txt" under:self.destDir];
    NAAssertNotNil(aPath, @"a.txt should exist after extracting 7z");

    NSString *contents = [NSString stringWithContentsOfFile:aPath
                                                   encoding:NSUTF8StringEncoding
                                                      error:nil];
    NAAssertEqualObjects(contents, @"file-a contents\n",
                         @"a.txt contents should match");
}

#pragma mark - Contents listing

- (void)testListContents {
    NSString *path = [NATestFixtures pathForFixture:@"test.7z"];
    NSError *error = nil;
    NSArray<NSString *> *entries = [self.extractor contentsOfArchiveAtPath:path
                                                                    error:&error];
    NAAssertNil(error, @"listing should not error");
    NAAssertNotNil(entries, @"entries should not be nil");
    NAAssertTrue(entries.count >= 3, @"should list at least 3 entries, got %lu",
                 (unsigned long)entries.count);
}

#pragma mark - canHandleFile

- (void)testCanHandle7z {
    NAAssertTrue([NA7zExtractor canHandleFileAtPath:
                  [NATestFixtures pathForFixture:@"test.7z"]]);
}

- (void)testCanHandleRejectsZip {
    NAAssertFalse([NA7zExtractor canHandleFileAtPath:
                   [NATestFixtures pathForFixture:@"test.zip"]]);
}

- (void)testCanHandleRejectsMissing {
    NAAssertFalse([NA7zExtractor canHandleFileAtPath:@"/nonexistent/file.7z"]);
}

#pragma mark - Supported extensions

- (void)testSupportedExtensions {
    NSArray<NSString *> *exts = [NA7zExtractor supportedExtensions];
    NAAssertTrue(exts.count > 0, @"should have supported extensions");
    NAAssertTrue([exts containsObject:@"7z"], @"should support 7z");
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
    NAAssertTrue(ok, @"extraction should succeed: %@", error.localizedDescription);
    NAAssertTrue(calls > 0, @"progress should be reported");
    NAAssertTrue(lastFraction == 1.0, @"last progress should be 1.0, got %f", lastFraction);
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

    NAAssertEqualObjects(fractions, (@[@0.0, @0.03, @0.97]),
                         @"fractions should be 0, 0.03, 0.97, got %@", fractions);
    NAAssertEqualObjects(entries, (@[@"", @"big.bin", @"big.bin"]),
                         @"entries should carry the file name, got %@", entries);
}

- (void)testListContentsExcludesArchivePath {
    NSString *path = [NATestFixtures pathForFixture:@"test.7z"];
    NSError *error = nil;
    NSArray<NSString *> *entries = [self.extractor contentsOfArchiveAtPath:path error:&error];
    NSSet *expected = [NSSet setWithObjects:@"src", @"src/subdir", @"src/a.txt", @"src/b.txt", @"src/subdir/c.txt", nil];
    NAAssertEqualObjects([NSSet setWithArray:entries], expected,
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

    NAAssertTrue(ok, @"archive path starting with - should extract: %@",
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

    NAAssertFalse(timedOut, @"extraction should not wait for a password");
    NAAssertFalse(ok, @"encrypted archive should fail");
    NAAssertTrue([error.localizedDescription containsString:@"password-protected"],
                 @"error should say the archive is password-protected, got %@",
                 error.localizedDescription);
    NAAssertTrue(error.localizedRecoverySuggestion.length > 0,
                 @"the password error should say what the user can do");
}

- (void)testListEncryptedArchiveFailsWithPasswordError {
    NSError *error = nil;
    NSArray *entries = [self.extractor contentsOfArchiveAtPath:
        [NATestFixtures pathForFixture:@"encrypted.7z"] error:&error];
    NAAssertNil(entries, @"listing an encrypted archive should fail");
    NAAssertTrue([error.localizedDescription containsString:@"password-protected"],
                 @"error should say the archive is password-protected, got %@",
                 error.localizedDescription);
}

- (void)testToolFailureKeepsStandardErrorAsFailureReason {
    NSError *error = nil;
    BOOL ok = [self.extractor extractArchiveAtPath:@"/nonexistent/file.7z"
                                     toDestination:self.destDir
                                          progress:nil
                                             error:&error];
    NAAssertFalse(ok, @"a missing archive should fail");
    NAAssertEqualObjects(error.localizedDescription, @"7zz could not extract the archive.",
                         @"the description should be a short summary, got %@",
                         error.localizedDescription);
    NAAssertTrue(error.localizedFailureReason.length > 0,
                 @"7zz stderr should be kept as the failure reason");
}

#pragma mark - Format type

// A file routed to this extractor by extension must be in its format; 7zz
// would otherwise detect and extract any format it supports, such as a disk
// image.
- (void)testOtherFormatWithThisExtensionIsNotExtracted {
    NSString *renamed = [NATestFixtures pathForFixture:@"disk-image.7z"];
    [[NSFileManager defaultManager] copyItemAtPath:[NATestFixtures pathForFixture:@"disk-image.dmg"]
                                            toPath:renamed error:nil];

    NAPluginManager *pm = [[NAPluginManager alloc] init];
    [pm registerBuiltinExtractors];
    id<NAExtractorPlugin> routed = [pm extractorForFileAtPath:renamed];

    NSError *error = nil;
    BOOL ok = [routed extractArchiveAtPath:renamed
                             toDestination:self.destDir
                                  progress:nil
                                     error:&error];
    [[NSFileManager defaultManager] removeItemAtPath:renamed error:nil];

    NAAssertTrue([routed isKindOfClass:[NA7zExtractor class]],
                 @"a .7z file no extractor claims by content is routed by extension");
    NAAssertFalse(ok, @"a disk image named .7z should not be extracted");
    NAAssertEqual([[NSFileManager defaultManager]
                      contentsOfDirectoryAtPath:self.destDir error:nil].count, 0u,
                  @"nothing should be written");
}

#pragma mark - Cancellation

- (void)testCancelBeforeExtractionReturnsCancelled {
    [self.extractor cancelExtraction];
    NSError *error = nil;
    BOOL ok = [self.extractor extractArchiveAtPath:[NATestFixtures pathForFixture:@"test.7z"]
                                     toDestination:self.destDir
                                          progress:nil
                                             error:&error];
    NAAssertFalse(ok, @"cancelled extraction should return NO");
    NAAssertTrue([error.domain isEqualToString:NSCocoaErrorDomain] &&
                 error.code == NSUserCancelledError,
                 @"error should be NSUserCancelledError, got %@", error);
    NAAssertEqual([[NSFileManager defaultManager]
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
    NAAssertFalse(ok, @"missing file should fail");
    NAAssertNotNil(error, @"error should be set");
}

#pragma mark - Helpers

- (NSString *)findFileNamed:(NSString *)name under:(NSString *)dir {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:dir];
    NSString *item;
    while ((item = [enumerator nextObject])) {
        if ([item.lastPathComponent isEqualToString:name]) {
            return [dir stringByAppendingPathComponent:item];
        }
    }
    return nil;
}

@end
