#import "NATestCase.h"
#import "NATestFixtures.h"
#import "Plugins/NALibarchiveExtractor.h"

@interface NALibarchiveExtractorTests : NATestCase
@property (nonatomic, strong) NALibarchiveExtractor *extractor;
@property (nonatomic, copy) NSString *destDir;
@end

@implementation NALibarchiveExtractorTests

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
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return; // xz not available
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
    NAAssertNil(error, @"listing should not error");
    NAAssertNotNil(entries, @"entries should not be nil");
    NAAssertTrue(entries.count >= 3, @"should list at least 3 entries, got %lu",
                 (unsigned long)entries.count);
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

    NAAssertTrue(ok, @"extraction should succeed");
    NAAssertTrue(callCount > 0, @"progress block should be called at least once");
    NAAssertTrue(lastFraction > 0, @"final fraction should be > 0");
}

#pragma mark - canHandleFile

- (void)testCanHandleValidArchive {
    NAAssertTrue([NALibarchiveExtractor canHandleFileAtPath:
                  [NATestFixtures pathForFixture:@"test.zip"]]);
}

- (void)testCanHandleRejectsCorrupt {
    NAAssertFalse([NALibarchiveExtractor canHandleFileAtPath:
                   [NATestFixtures pathForFixture:@"corrupt.zip"]]);
}

- (void)testCanHandleRejectsMissing {
    NAAssertFalse([NALibarchiveExtractor canHandleFileAtPath:
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
    NAAssertFalse(ok, @"corrupt archive should fail");
    NAAssertNotNil(error, @"error should be set");
}

- (void)testExtractMissingFileFails {
    NSError *error = nil;
    BOOL ok = [self.extractor extractArchiveAtPath:@"/nonexistent/file.zip"
                                     toDestination:self.destDir
                                          progress:nil
                                             error:&error];
    NAAssertFalse(ok, @"missing file should fail");
    NAAssertNotNil(error, @"error should be set");
}

#pragma mark - Supported extensions

- (void)testSupportedExtensions {
    NSArray<NSString *> *exts = [NALibarchiveExtractor supportedExtensions];
    NAAssertTrue(exts.count > 0, @"should have supported extensions");
    NAAssertTrue([exts containsObject:@"zip"], @"should support zip");
    NAAssertTrue([exts containsObject:@"tar"], @"should support tar");
    NAAssertTrue([exts containsObject:@"gz"], @"should support gz");
}

#pragma mark - Helpers

- (void)assertExtractsFixture:(NSString *)name {
    NSString *path = [NATestFixtures pathForFixture:name];
    NAAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:path],
                 @"fixture %@ should exist", name);

    NSError *error = nil;
    BOOL ok = [self.extractor extractArchiveAtPath:path
                                     toDestination:self.destDir
                                          progress:nil
                                             error:&error];
    NAAssertTrue(ok, @"extraction of %@ should succeed: %@", name,
                 error.localizedDescription);

    // Verify extracted content.
    NSString *aPath = [self findFileNamed:@"a.txt" under:self.destDir];
    NAAssertNotNil(aPath, @"a.txt should exist after extracting %@", name);

    NSString *contents = [NSString stringWithContentsOfFile:aPath
                                                   encoding:NSUTF8StringEncoding
                                                      error:nil];
    NAAssertEqualObjects(contents, @"file-a contents\n",
                         @"a.txt contents should match after extracting %@", name);
}

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
