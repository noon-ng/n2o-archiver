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
