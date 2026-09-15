#import <XCTest/XCTest.h>
#import "NATestFixtures.h"
#import "NAPluginManager.h"
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

- (void)testListContentsExcludesArchivePath {
    NSString *path = [NATestFixtures pathForFixture:@"test.rar"];
    NSError *error = nil;
    NSArray<NSString *> *entries = [self.extractor contentsOfArchiveAtPath:path error:&error];
    NSSet *expected = [NSSet setWithObjects:@"src/a.txt", @"src/b.txt", @"src/subdir/c.txt", nil];
    XCTAssertEqualObjects([NSSet setWithArray:entries], expected,
                         @"entries should be the archive members only, got %@ (%@)",
                         entries, error);
}

#pragma mark - Format type

// A file routed to this extractor by extension must be in its format; 7zz
// would otherwise detect and extract any format it supports, such as a disk
// image.
- (void)testOtherFormatWithThisExtensionIsNotExtracted {
    NSString *renamed = [NATestFixtures pathForFixture:@"disk-image.rar"];
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

    XCTAssertTrue([routed isKindOfClass:[NARarExtractor class]],
                 @"a .rar file no extractor claims by content is routed by extension");
    XCTAssertFalse(ok, @"a disk image named .rar should not be extracted");
    XCTAssertEqual([[NSFileManager defaultManager]
                      contentsOfDirectoryAtPath:self.destDir error:nil].count, 0u,
                  @"nothing should be written");
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

- (void)testSupportedExtensionsExcludeContinuationVolumes {
    XCTAssertFalse([[NARarExtractor supportedExtensions] containsObject:@"r00"],
                  @".r00 is a continuation volume, not an archive to open");
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
