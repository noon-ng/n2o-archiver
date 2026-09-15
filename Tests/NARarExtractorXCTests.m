#import <XCTest/XCTest.h>
#import "NATestFixtures.h"
#import "Plugins/NARarExtractor.h"

@interface NARarExtractorXCTests : XCTestCase
@property (nonatomic, strong) NARarExtractor *extractor;
@property (nonatomic, copy) NSString *destDir;
@end

@implementation NARarExtractorXCTests

+ (void)setUp {
    [NATestFixtures setUp];
}

+ (void)tearDown {
    [NATestFixtures tearDown];
}

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
    NSString *path = [NATestFixtures pathForFixture:@"test.rar"];
    NSError *error = nil;
    NSArray<NSString *> *entries = [self.extractor contentsOfArchiveAtPath:path
                                                                    error:&error];
    XCTAssertNil(error);
    XCTAssertNotNil(entries);
    XCTAssertGreaterThanOrEqual(entries.count, 3u);
}

#pragma mark - canHandleFile

- (void)testCanHandleRar {
    XCTAssertTrue([NARarExtractor canHandleFileAtPath:
                   [NATestFixtures pathForFixture:@"test.rar"]]);
}

- (void)testCanHandleRejectsZip {
    XCTAssertFalse([NARarExtractor canHandleFileAtPath:
                    [NATestFixtures pathForFixture:@"test.zip"]]);
}

- (void)testCanHandleRejectsMissing {
    XCTAssertFalse([NARarExtractor canHandleFileAtPath:@"/nonexistent/file.rar"]);
}

#pragma mark - Supported extensions

- (void)testSupportedExtensions {
    NSArray<NSString *> *exts = [NARarExtractor supportedExtensions];
    XCTAssertGreaterThan(exts.count, 0u);
    XCTAssertTrue([exts containsObject:@"rar"]);
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
    XCTAssertTrue(ok, @"extraction should succeed: %@", error.localizedDescription);
    XCTAssertTrue(calls > 0, @"progress should be reported");
    XCTAssertTrue(lastFraction == 1.0, @"last progress should be 1.0, got %f", lastFraction);
}

#pragma mark - Cancellation

- (void)testCancelBeforeExtractionReturnsCancelled {
    [self.extractor cancelExtraction];
    NSError *error = nil;
    BOOL ok = [self.extractor extractArchiveAtPath:[NATestFixtures pathForFixture:@"test.rar"]
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
    BOOL ok = [self.extractor extractArchiveAtPath:@"/nonexistent/file.rar"
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
