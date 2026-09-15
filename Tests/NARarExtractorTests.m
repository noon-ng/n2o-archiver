#import "NATestCase.h"
#import "NATestFixtures.h"
#import "Plugins/NARarExtractor.h"

@interface NARarExtractorTests : NATestCase
@property (nonatomic, strong) NARarExtractor *extractor;
@property (nonatomic, copy) NSString *destDir;
@end

@implementation NARarExtractorTests

- (void)setUp {
    [super setUp];
    self.extractor = [[NARarExtractor alloc] init];
    self.destDir = [NSTemporaryDirectory()
        stringByAppendingPathComponent:
            [NSString stringWithFormat:@"n2o-rar-test-%u", arc4random()]];
    [[NSFileManager defaultManager] createDirectoryAtPath:self.destDir
                              withIntermediateDirectories:YES
                                               attributes:nil error:nil];
}

- (void)tearDown {
    [[NSFileManager defaultManager] removeItemAtPath:self.destDir error:nil];
    [super tearDown];
}

#pragma mark - Extraction

- (void)testExtractRar {
    NSString *path = [NATestFixtures pathForFixture:@"test.rar"];
    NAAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:path],
                 @"test.rar fixture should exist");

    NSError *error = nil;
    BOOL ok = [self.extractor extractArchiveAtPath:path
                                      toDestination:self.destDir
                                           progress:nil
                                              error:&error];
    NAAssertTrue(ok, @"RAR extraction should succeed: %@", error.localizedDescription);

    NSString *aPath = [self findFileNamed:@"a.txt" under:self.destDir];
    NAAssertNotNil(aPath, @"a.txt should exist after extracting RAR");

    NSString *contents = [NSString stringWithContentsOfFile:aPath
                                                   encoding:NSUTF8StringEncoding
                                                      error:nil];
    NAAssertEqualObjects(contents, @"file-a contents\n",
                         @"a.txt contents should match");
}

#pragma mark - Contents listing

- (void)testListContents {
    NSString *path = [NATestFixtures pathForFixture:@"test.rar"];
    NSError *error = nil;
    NSArray<NSString *> *entries = [self.extractor contentsOfArchiveAtPath:path
                                                                    error:&error];
    NAAssertNil(error, @"listing should not error");
    NAAssertNotNil(entries, @"entries should not be nil");
    NAAssertTrue(entries.count >= 3, @"should list at least 3 entries, got %lu",
                 (unsigned long)entries.count);
}

#pragma mark - canHandleFile

- (void)testCanHandleRar {
    NAAssertTrue([NARarExtractor canHandleFileAtPath:
                  [NATestFixtures pathForFixture:@"test.rar"]]);
}

- (void)testCanHandleRejectsZip {
    NAAssertFalse([NARarExtractor canHandleFileAtPath:
                   [NATestFixtures pathForFixture:@"test.zip"]]);
}

- (void)testCanHandleRejectsMissing {
    NAAssertFalse([NARarExtractor canHandleFileAtPath:@"/nonexistent/file.rar"]);
}

#pragma mark - Supported extensions

- (void)testSupportedExtensions {
    NSArray<NSString *> *exts = [NARarExtractor supportedExtensions];
    NAAssertTrue(exts.count > 0, @"should have supported extensions");
    NAAssertTrue([exts containsObject:@"rar"], @"should support rar");
}

#pragma mark - Progress

- (void)testProgressReachesCompletion {
    __block NSUInteger calls = 0;
    __block double lastFraction = -1;
    NSError *error = nil;
    BOOL ok = [self.extractor extractArchiveAtPath:[NATestFixtures pathForFixture:@"test.rar"]
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

- (void)testListContentsExcludesArchivePath {
    NSString *path = [NATestFixtures pathForFixture:@"test.rar"];
    NSError *error = nil;
    NSArray<NSString *> *entries = [self.extractor contentsOfArchiveAtPath:path error:&error];
    NSSet *expected = [NSSet setWithObjects:@"src/a.txt", @"src/b.txt", @"src/subdir/c.txt", nil];
    NAAssertEqualObjects([NSSet setWithArray:entries], expected,
                         @"entries should be the archive members only, got %@ (%@)",
                         entries, error);
}

#pragma mark - Cancellation

- (void)testCancelBeforeExtractionReturnsCancelled {
    [self.extractor cancelExtraction];
    NSError *error = nil;
    BOOL ok = [self.extractor extractArchiveAtPath:[NATestFixtures pathForFixture:@"test.rar"]
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

- (void)testSupportedExtensionsExcludeContinuationVolumes {
    NAAssertFalse([[NARarExtractor supportedExtensions] containsObject:@"r00"],
                  @".r00 is a continuation volume, not an archive to open");
}

#pragma mark - Error handling

- (void)testExtractMissingFileFails {
    NSError *error = nil;
    BOOL ok = [self.extractor extractArchiveAtPath:@"/nonexistent/file.rar"
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
