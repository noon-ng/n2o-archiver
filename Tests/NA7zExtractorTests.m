#import "NATestCase.h"
#import "NATestFixtures.h"
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
