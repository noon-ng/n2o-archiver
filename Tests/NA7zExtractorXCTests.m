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
