#import "NATestCase.h"
#import "NAQuarantine.h"
#include <sys/stat.h>
#include <sys/xattr.h>

@interface NAQuarantineTests : NATestCase
@property (nonatomic, copy) NSString *workDir;
@end

@implementation NAQuarantineTests

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
            chmod(path.fileSystemRepresentation, (st.st_mode & 07777) | S_IWUSR);
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
    NAAssertTrue(ok, @"quarantine should be copied: %@", error.localizedDescription);

    for (NSString *item in @[@"", @"plain.txt", @"sub", @"sub/nested.txt", @"read-only.txt",
                             @"locked", @"locked/inside.txt", @"link"]) {
        NSString *path = [root stringByAppendingPathComponent:item];
        NAAssertEqualObjects([self quarantineAtPath:path], @(kValue),
                             @"%@ should carry the quarantine value", item.length ? item : @"root");
    }

    struct stat st;
    lstat(readOnlyFile.fileSystemRepresentation, &st);
    NAAssertTrue((st.st_mode & 07777) == 0444, @"read-only file mode should be restored");
    lstat(readOnlyDir.fileSystemRepresentation, &st);
    NAAssertTrue((st.st_mode & 07777) == 0555, @"read-only directory mode should be restored");
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

    NAAssertTrue([self quarantineAtPath:outside] == nil,
                 @"the symlink target outside the tree should not be marked");
}

- (void)testUnquarantinedSourceLeavesTreeUnchanged {
    NSString *archive = [self writeFile:@"archive.zip"];
    NSString *file = [self writeFile:@"out/plain.txt"];

    NSError *error = nil;
    BOOL ok = [NAQuarantine copyQuarantineFromPath:archive
                                      toTreeAtPath:[self.workDir stringByAppendingPathComponent:@"out"]
                                             error:&error];

    NAAssertTrue(ok, @"no quarantine on the source is not an error");
    NAAssertTrue([self quarantineAtPath:file] == nil, @"file should not be marked");
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

    NAAssertFalse(ok, @"an item that cannot be marked should be reported");
    NAAssertEqualObjects(error.userInfo[NSFilePathErrorKey], immutable,
                         @"error should name the item, got %@", error);
    NAAssertEqualObjects([self quarantineAtPath:[root stringByAppendingPathComponent:@"plain.txt"]],
                         @(kValue), @"other items should still be marked");
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
