#import "NATestCase.h"
#import "NAQuarantine.h"
#include <sys/stat.h>
#include <sys/xattr.h>

// Private test hook: called with each item's path just before it is opened.
@interface NAQuarantine (Testing)
+ (void)setWillOpenItemHandler:(void (^)(NSString *path))handler;
@end

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
    NAAssertTrue([error.localizedRecoverySuggestion containsString:immutable],
                 @"the recovery suggestion should explain the consequence and name the item, got %@",
                 error.localizedRecoverySuggestion);
    NAAssertEqualObjects([self quarantineAtPath:[root stringByAppendingPathComponent:@"plain.txt"]],
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

    NAAssertTrue(ok, @"an unreadable directory should be made listable and marked: %@", error);
    NAAssertEqualObjects([self quarantineAtPath:[locked stringByAppendingPathComponent:@"inside.txt"]],
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

    NAAssertFalse(ok, @"a directory that cannot be listed should be reported, not skipped");
    NAAssertEqualObjects(error.userInfo[NSFilePathErrorKey], sealed,
                         @"the error should name the directory, got %@", error);
}

#pragma mark - Items replaced during the walk

// Another account with write access to the output could replace an item with
// a symlink between the walk checking it and changing it. The hook runs at
// that point.
- (void)testDirectoryReplacedBySymlinkIsNotFollowed {
    NSString *archive = [self writeFile:@"archive.zip"];
    setxattr(archive.fileSystemRepresentation, "com.apple.quarantine", kValue, strlen(kValue), 0, 0);
    NSString *outsideFile = [self writeFile:@"outside/secret.txt"];
    NSString *outside = outsideFile.stringByDeletingLastPathComponent;
    NSString *root = [self.workDir stringByAppendingPathComponent:@"out"];
    NSString *inner = [[self writeFile:@"out/inner/file.txt"] stringByDeletingLastPathComponent];

    [NAQuarantine setWillOpenItemHandler:^(NSString *path) {
        if ([path isEqualToString:inner]) {
            [[NSFileManager defaultManager] removeItemAtPath:inner error:nil];
            symlink(outside.fileSystemRepresentation, inner.fileSystemRepresentation);
        }
    }];
    NSError *error = nil;
    [NAQuarantine copyQuarantineFromPath:archive toTreeAtPath:root error:&error];
    [NAQuarantine setWillOpenItemHandler:nil];

    NAAssertNil([self quarantineAtPath:outsideFile],
                @"a file reached through the swapped-in symlink should not be marked");
    NAAssertNil([self quarantineAtPath:outside],
                @"the symlink target should not be marked");
}

- (void)testReadOnlyFileReplacedBySymlinkKeepsTargetMode {
    NSString *archive = [self writeFile:@"archive.zip"];
    setxattr(archive.fileSystemRepresentation, "com.apple.quarantine", kValue, strlen(kValue), 0, 0);
    NSString *outsideFile = [self writeFile:@"outside/readonly.txt"];
    chmod(outsideFile.fileSystemRepresentation, 0444);
    NSString *root = [self.workDir stringByAppendingPathComponent:@"out"];
    NSString *readOnly = [self writeFile:@"out/readonly.txt"];
    chmod(readOnly.fileSystemRepresentation, 0444);
    struct stat before;
    stat(outsideFile.fileSystemRepresentation, &before);

    [NAQuarantine setWillOpenItemHandler:^(NSString *path) {
        if ([path isEqualToString:readOnly]) {
            unlink(readOnly.fileSystemRepresentation);
            symlink(outsideFile.fileSystemRepresentation, readOnly.fileSystemRepresentation);
        }
    }];
    NSError *error = nil;
    [NAQuarantine copyQuarantineFromPath:archive toTreeAtPath:root error:&error];
    [NAQuarantine setWillOpenItemHandler:nil];

    struct stat st;
    stat(outsideFile.fileSystemRepresentation, &st);
    NAAssertTrue((st.st_mode & 07777) == 0444,
                 @"the symlink target's mode should not change, got %o", st.st_mode & 07777);
    // A chmod that is undone afterwards still updates the change time.
    NAAssertTrue(st.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec &&
                 st.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec,
                 @"the symlink target should not have been changed at all");
    NAAssertNil([self quarantineAtPath:outsideFile],
                @"the symlink target should not be marked");
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
