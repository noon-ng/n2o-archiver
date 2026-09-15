#import <XCTest/XCTest.h>
#import "NAQuarantine.h"
#include <sys/stat.h>
#include <sys/xattr.h>

@interface NAQuarantineXCTests : XCTestCase
@property (nonatomic, copy) NSString *workDir;
@end

@implementation NAQuarantineXCTests

static const char *const kValue = "0083;00000000;N2OArchiverTests;";

- (void)setUp {
    [super setUp];
    self.workDir = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"n2o-quarantine-%u", arc4random()]];
    [[NSFileManager defaultManager] createDirectoryAtPath:self.workDir
                              withIntermediateDirectories:YES
                                               attributes:nil error:nil];
}

- (void)tearDown {
    // Restore write permission so read-only test items can be removed.
    NSFileManager *fm = [NSFileManager defaultManager];
    chmod(self.workDir.fileSystemRepresentation, 0755);
    for (NSString *item in [fm enumeratorAtPath:self.workDir]) {
        NSString *path = [self.workDir stringByAppendingPathComponent:item];
        struct stat st;
        if (lstat(path.fileSystemRepresentation, &st) == 0 && !S_ISLNK(st.st_mode)) {
            chflags(path.fileSystemRepresentation, 0);
            chmod(path.fileSystemRepresentation,
                  (st.st_mode & 07777) | (S_ISDIR(st.st_mode) ? 0700 : S_IWUSR));
        }
    }
    [fm removeItemAtPath:self.workDir error:nil];
    [super tearDown];
}

#pragma mark - Copying

- (void)testCopiesQuarantineToEveryItemIncludingReadOnly {
    NSString *archive = [self writeFile:@"archive.zip"];
    setxattr(archive.fileSystemRepresentation, "com.apple.quarantine",
             kValue, strlen(kValue), 0, 0);

    NSString *root = [self.workDir stringByAppendingPathComponent:@"out"];
    [self writeFile:@"out/plain.txt"];
    [self writeFile:@"out/sub/nested.txt"];
    NSString *readOnlyFile = [self writeFile:@"out/read-only.txt"];
    [self writeFile:@"out/locked/inside.txt"];
    NSString *readOnlyDir = [root stringByAppendingPathComponent:@"locked"];
    [[NSFileManager defaultManager]
        createSymbolicLinkAtPath:[root stringByAppendingPathComponent:@"link"]
             withDestinationPath:@"plain.txt" error:nil];
    chmod(readOnlyFile.fileSystemRepresentation, 0444);
    chmod(readOnlyDir.fileSystemRepresentation, 0555);

    NSError *error = nil;
    BOOL ok = [NAQuarantine copyQuarantineFromPath:archive toTreeAtPath:root error:&error];
    XCTAssertTrue(ok, @"quarantine should be copied: %@", error.localizedDescription);

    for (NSString *item in @[@"", @"plain.txt", @"sub", @"sub/nested.txt", @"read-only.txt",
                             @"locked", @"locked/inside.txt", @"link"]) {
        NSString *path = [root stringByAppendingPathComponent:item];
        XCTAssertEqualObjects([self quarantineAtPath:path], @(kValue),
                             @"%@ should carry the quarantine value", item.length ? item : @"root");
    }

    struct stat st;
    lstat(readOnlyFile.fileSystemRepresentation, &st);
    XCTAssertTrue((st.st_mode & 07777) == 0444, @"read-only file mode should be restored");
    lstat(readOnlyDir.fileSystemRepresentation, &st);
    XCTAssertTrue((st.st_mode & 07777) == 0555, @"read-only directory mode should be restored");
}

- (void)testSymlinkTargetOutsideTreeIsNotMarked {
    NSString *archive = [self writeFile:@"archive.zip"];
    setxattr(archive.fileSystemRepresentation, "com.apple.quarantine",
             kValue, strlen(kValue), 0, 0);
    NSString *outside = [self writeFile:@"outside.txt"];
    NSString *root = [self.workDir stringByAppendingPathComponent:@"out"];
    [[NSFileManager defaultManager] createDirectoryAtPath:root
                              withIntermediateDirectories:YES
                                               attributes:nil error:nil];
    [[NSFileManager defaultManager]
        createSymbolicLinkAtPath:[root stringByAppendingPathComponent:@"link"]
             withDestinationPath:outside error:nil];

    [NAQuarantine copyQuarantineFromPath:archive toTreeAtPath:root error:nil];

    XCTAssertTrue([self quarantineAtPath:outside] == nil,
                 @"the symlink target outside the tree should not be marked");
}

- (void)testUnquarantinedSourceLeavesTreeUnchanged {
    NSString *archive = [self writeFile:@"archive.zip"];
    NSString *file = [self writeFile:@"out/plain.txt"];

    NSError *error = nil;
    BOOL ok = [NAQuarantine copyQuarantineFromPath:archive
                                      toTreeAtPath:[self.workDir stringByAppendingPathComponent:@"out"]
                                             error:&error];

    XCTAssertTrue(ok, @"no quarantine on the source is not an error");
    XCTAssertTrue([self quarantineAtPath:file] == nil, @"file should not be marked");
}

- (void)testReportsItemsThatCannotBeMarked {
    NSString *archive = [self writeFile:@"archive.zip"];
    setxattr(archive.fileSystemRepresentation, "com.apple.quarantine",
             kValue, strlen(kValue), 0, 0);
    NSString *root = [self.workDir stringByAppendingPathComponent:@"out"];
    [self writeFile:@"out/plain.txt"];
    NSString *immutable = [self writeFile:@"out/immutable.txt"];
    chflags(immutable.fileSystemRepresentation, UF_IMMUTABLE);

    NSError *error = nil;
    BOOL ok = [NAQuarantine copyQuarantineFromPath:archive toTreeAtPath:root error:&error];

    XCTAssertFalse(ok, @"an item that cannot be marked should be reported");
    XCTAssertEqualObjects(error.userInfo[NSFilePathErrorKey], immutable,
                         @"error should name the item, got %@", error);
    XCTAssertTrue([error.localizedRecoverySuggestion containsString:immutable],
                 @"the recovery suggestion should explain the consequence and name the item, got %@",
                 error.localizedRecoverySuggestion);
    XCTAssertEqualObjects([self quarantineAtPath:[root stringByAppendingPathComponent:@"plain.txt"]],
                         @(kValue), @"other items should still be marked");
}

- (void)testMarksItemsInsideUnreadableDirectory {
    NSString *archive = [self writeFile:@"archive.zip"];
    setxattr(archive.fileSystemRepresentation, "com.apple.quarantine",
             kValue, strlen(kValue), 0, 0);
    NSString *root = [self.workDir stringByAppendingPathComponent:@"out"];
    [self writeFile:@"out/locked/inside.txt"];
    NSString *locked = [root stringByAppendingPathComponent:@"locked"];
    chmod(locked.fileSystemRepresentation, 0000);

    NSError *error = nil;
    BOOL ok = [NAQuarantine copyQuarantineFromPath:archive toTreeAtPath:root error:&error];

    XCTAssertTrue(ok, @"an unreadable directory should be made listable and marked: %@", error);
    XCTAssertEqualObjects([self quarantineAtPath:[locked stringByAppendingPathComponent:@"inside.txt"]],
                         @(kValue), @"the file inside the unreadable directory should be marked");
}

- (void)testReportsDirectoryThatCannotBeListed {
    NSString *archive = [self writeFile:@"archive.zip"];
    setxattr(archive.fileSystemRepresentation, "com.apple.quarantine",
             kValue, strlen(kValue), 0, 0);
    NSString *root = [self.workDir stringByAppendingPathComponent:@"out"];
    [self writeFile:@"out/sealed/inside.txt"];
    NSString *sealed = [root stringByAppendingPathComponent:@"sealed"];
    chmod(sealed.fileSystemRepresentation, 0000);
    chflags(sealed.fileSystemRepresentation, UF_IMMUTABLE);

    NSError *error = nil;
    BOOL ok = [NAQuarantine copyQuarantineFromPath:archive toTreeAtPath:root error:&error];

    XCTAssertFalse(ok, @"a directory that cannot be listed should be reported, not skipped");
    XCTAssertEqualObjects(error.userInfo[NSFilePathErrorKey], sealed,
                         @"the error should name the directory, got %@", error);
}

#pragma mark - Helpers

- (NSString *)writeFile:(NSString *)relativePath {
    NSString *path = [self.workDir stringByAppendingPathComponent:relativePath];
    [[NSFileManager defaultManager]
        createDirectoryAtPath:path.stringByDeletingLastPathComponent
  withIntermediateDirectories:YES attributes:nil error:nil];
    [relativePath writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
    return path;
}

- (NSString *)quarantineAtPath:(NSString *)path {
    char buffer[256];
    ssize_t length = getxattr(path.fileSystemRepresentation, "com.apple.quarantine",
                              buffer, sizeof(buffer), 0, XATTR_NOFOLLOW);
    if (length <= 0) return nil;
    return [[NSString alloc] initWithBytes:buffer length:(NSUInteger)length
                                  encoding:NSUTF8StringEncoding];
}

@end
