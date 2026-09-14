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
