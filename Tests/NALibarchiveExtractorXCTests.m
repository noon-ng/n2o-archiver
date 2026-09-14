#import <XCTest/XCTest.h>
#import "NATestFixtures.h"
#import "Plugins/NALibarchiveExtractor.h"

@interface NALibarchiveExtractorXCTests : XCTestCase
@property (nonatomic, strong) NALibarchiveExtractor *extractor;
@property (nonatomic, copy) NSString *destDir;
@end

@implementation NALibarchiveExtractorXCTests

+ (void)setUp {
    [NATestFixtures setUp];
}

+ (void)tearDown {
    [NATestFixtures tearDown];
}

- (void)setUp {
    [super setUp];
    self.extractor = [[NALibarchiveExtractor alloc] init];
    self.destDir = [NSTemporaryDirectory()
        stringByAppendingPathComponent:
            [NSString stringWithFormat:@"n2o-extract-%u", arc4random()]];
    [[NSFileManager defaultManager] createDirectoryAtPath:self.destDir
                              withIntermediateDirectories:YES
                                               attributes:nil error:nil];
}

- (void)tearDown {
    [[NSFileManager defaultManager] removeItemAtPath:self.destDir error:nil];
    [super tearDown];
}

#pragma mark - Format tests

- (void)testExtractZip {
    [self assertExtractsFixture:@"test.zip"];
}

- (void)testExtractTar {
    [self assertExtractsFixture:@"test.tar"];
}

- (void)testExtractTarGz {
    [self assertExtractsFixture:@"test.tar.gz"];
}

- (void)testExtractTarBz2 {
    [self assertExtractsFixture:@"test.tar.bz2"];
}

- (void)testExtractTarXz {
    NSString *path = [NATestFixtures pathForFixture:@"test.tar.xz"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return;
    [self assertExtractsFixture:@"test.tar.xz"];
}

- (void)testExtractCpio {
    [self assertExtractsFixture:@"test.cpio"];
}

#pragma mark - Contents listing

- (void)testListContents {
    NSString *path = [NATestFixtures pathForFixture:@"test.zip"];
    NSError *error = nil;
    NSArray<NSString *> *entries = [self.extractor contentsOfArchiveAtPath:path
                                                                    error:&error];
    XCTAssertNil(error);
    XCTAssertNotNil(entries);
    XCTAssertGreaterThanOrEqual(entries.count, 3u);
}

#pragma mark - Progress reporting

- (void)testProgressReported {
    NSString *path = [NATestFixtures pathForFixture:@"test.zip"];
    __block int callCount = 0;
    __block double lastFraction = -1;

    NSError *error = nil;
    BOOL ok = [self.extractor extractArchiveAtPath:path
                                     toDestination:self.destDir
                                          progress:^(double fraction, NSString *entry) {
        callCount++;
        lastFraction = fraction;
    }
                                             error:&error];

    XCTAssertTrue(ok);
    XCTAssertGreaterThan(callCount, 0);
    XCTAssertGreaterThan(lastFraction, 0.0);
}

#pragma mark - canHandleFile

- (void)testCanHandleValidArchive {
    XCTAssertTrue([NALibarchiveExtractor canHandleFileAtPath:
                   [NATestFixtures pathForFixture:@"test.zip"]]);
}

- (void)testCanHandleRejectsCorrupt {
    XCTAssertFalse([NALibarchiveExtractor canHandleFileAtPath:
                    [NATestFixtures pathForFixture:@"corrupt.zip"]]);
}

- (void)testCanHandleRejectsMissing {
    XCTAssertFalse([NALibarchiveExtractor canHandleFileAtPath:
                    @"/nonexistent/file.zip"]);
}

#pragma mark - Error handling

- (void)testExtractCorruptArchiveFails {
    NSString *path = [NATestFixtures pathForFixture:@"corrupt.zip"];
    NSError *error = nil;
    BOOL ok = [self.extractor extractArchiveAtPath:path
                                     toDestination:self.destDir
                                          progress:nil
                                             error:&error];
    XCTAssertFalse(ok);
    XCTAssertNotNil(error);
}

- (void)testExtractMissingFileFails {
    NSError *error = nil;
    BOOL ok = [self.extractor extractArchiveAtPath:@"/nonexistent/file.zip"
                                     toDestination:self.destDir
                                          progress:nil
                                             error:&error];
    XCTAssertFalse(ok);
    XCTAssertNotNil(error);
}

#pragma mark - Path traversal

// Each traversal fixture is extracted into destDir/out; files the archive
// tries to place outside that directory would land in destDir.

- (void)testDotDotEntryDoesNotEscapeDestination {
    NSError *error = nil;
    BOOL ok = [self extractTraversalFixture:@"traversal-dotdot.zip" error:&error];
    XCTAssertFalse(ok, @"archive with ../ entry should fail");
    XCTAssertNotNil(error, @"error should be set");
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:
                   [self.destDir stringByAppendingPathComponent:@"canary.txt"]],
                  @"../canary.txt should not be written outside the destination");
}

- (void)testSymlinkEntryDoesNotEscapeDestination {
    NSError *error = nil;
    BOOL ok = [self extractTraversalFixture:@"traversal-symlink.tar" error:&error];
    XCTAssertFalse(ok, @"archive writing through a symlink should fail");
    XCTAssertNotNil(error, @"error should be set");
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:
                   [self.destDir stringByAppendingPathComponent:@"canary.txt"]],
                  @"link/canary.txt should not be written through the symlink");
}

- (void)testHardlinkEntryDoesNotEscapeDestination {
    NSString *victim = [self.destDir stringByAppendingPathComponent:@"victim.txt"];
    [@"original" writeToFile:victim atomically:NO
                    encoding:NSUTF8StringEncoding error:nil];

    NSError *error = nil;
    BOOL ok = [self extractTraversalFixture:@"traversal-hardlink.tar" error:&error];
    XCTAssertFalse(ok, @"archive with hardlink to ../ should fail");
    XCTAssertNotNil(error, @"error should be set");

    NSDictionary *attrs = [[NSFileManager defaultManager]
        attributesOfItemAtPath:victim error:nil];
    XCTAssertEqual([attrs[NSFileReferenceCount] integerValue], 1,
                  @"file outside the destination should not gain a hardlink");
}

- (void)testAbsoluteEntryIsPlacedUnderDestination {
    NSError *error = nil;
    BOOL ok = [self extractTraversalFixture:@"traversal-absolute.tar" error:&error];
    XCTAssertTrue(ok, @"absolute entry should extract under the destination: %@",
                 error.localizedDescription);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:
                  [self.destDir stringByAppendingPathComponent:@"out/absolute.txt"]],
                 @"/absolute.txt should be written to out/absolute.txt");
}

#pragma mark - Supported extensions

- (void)testSupportedExtensions {
    NSArray<NSString *> *exts = [NALibarchiveExtractor supportedExtensions];
    XCTAssertGreaterThan(exts.count, 0u);
    XCTAssertTrue([exts containsObject:@"zip"]);
    XCTAssertTrue([exts containsObject:@"tar"]);
    XCTAssertTrue([exts containsObject:@"gz"]);
}

#pragma mark - Helpers

- (void)assertExtractsFixture:(NSString *)name {
    NSString *path = [NATestFixtures pathForFixture:name];
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:path],
                  @"fixture %@ should exist", name);

    NSError *error = nil;
    BOOL ok = [self.extractor extractArchiveAtPath:path
                                     toDestination:self.destDir
                                          progress:nil
                                             error:&error];
    XCTAssertTrue(ok, @"extraction of %@ failed: %@", name, error.localizedDescription);

    NSString *aPath = [self findFileNamed:@"a.txt" under:self.destDir];
    XCTAssertNotNil(aPath, @"a.txt should exist after extracting %@", name);

    NSString *contents = [NSString stringWithContentsOfFile:aPath
                                                   encoding:NSUTF8StringEncoding
                                                      error:nil];
    XCTAssertEqualObjects(contents, @"file-a contents\n");
}

- (BOOL)extractTraversalFixture:(NSString *)name error:(NSError **)error {
    NSString *out = [self.destDir stringByAppendingPathComponent:@"out"];
    [[NSFileManager defaultManager] createDirectoryAtPath:out
                              withIntermediateDirectories:YES
                                               attributes:nil error:nil];
    return [self.extractor extractArchiveAtPath:[NATestFixtures pathForFixture:name]
                                  toDestination:out
                                       progress:nil
                                          error:error];
}

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
