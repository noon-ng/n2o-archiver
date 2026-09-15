#import "NAQuarantine.h"
#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <unistd.h>

NSString *const NAQuarantineErrorDomain = @"sh.n2o.archiver.quarantine";

static const char *const kQuarantineAttribute = "com.apple.quarantine";

// Test hook, called with an item's path after it has been examined and before
// it is opened. Set through +setWillOpenItemHandler:, which is not in the
// header.
static void (^NAWillOpenItemHandler)(NSString *path);

@implementation NAQuarantine

+ (void)setWillOpenItemHandler:(nullable void (^)(NSString *path))handler {
    NAWillOpenItemHandler = [handler copy];
}

+ (BOOL)copyQuarantineFromPath:(NSString *)sourcePath
                  toTreeAtPath:(NSString *)rootPath
                         error:(NSError **)error {
    NSData *value = [self quarantineValueAtPath:sourcePath];
    if (!value) return YES;

    NSMutableArray<NSString *> *failed = [NSMutableArray array];
    [self markItemNamed:rootPath.fileSystemRepresentation
            inDirectory:AT_FDCWD
                   path:rootPath
                  value:value
                 failed:failed];

    if (failed.count == 0) return YES;

    if (error) {
        NSString *description = failed.count == 1
            ? @"1 extracted item could not be marked as downloaded from the internet."
            : [NSString stringWithFormat:
                @"%lu extracted items could not be marked as downloaded from the internet.",
                (unsigned long)failed.count];
        NSString *suggestion = [NSString stringWithFormat:
            @"macOS will not check %@ before %@. %@: %@",
            failed.count == 1 ? @"this item" : @"these items",
            failed.count == 1 ? @"it opens" : @"they open",
            failed.count == 1 ? @"Item" : @"First item",
            failed.firstObject];
        *error = [NSError errorWithDomain:NAQuarantineErrorDomain
                                     code:1
                                 userInfo:@{NSLocalizedDescriptionKey: description,
                                            NSLocalizedRecoverySuggestionErrorKey: suggestion,
                                            NSFilePathErrorKey: failed.firstObject}];
    }
    return NO;
}

#pragma mark - Private

+ (nullable NSData *)quarantineValueAtPath:(NSString *)path {
    const char *p = path.fileSystemRepresentation;
    ssize_t size = getxattr(p, kQuarantineAttribute, NULL, 0, 0, 0);
    if (size <= 0) return nil;

    NSMutableData *value = [NSMutableData dataWithLength:(NSUInteger)size];
    size = getxattr(p, kQuarantineAttribute, value.mutableBytes, value.length, 0, 0);
    if (size <= 0) return nil;
    value.length = (NSUInteger)size;
    return value;
}

// Marks the item `name` in the directory `parentFD` and, for a directory, the
// items below it. Each item is opened relative to its parent's descriptor
// with O_NOFOLLOW (O_SYMLINK for a symlink, which is marked itself) and changed
// through its own descriptor. If another process replaces an item with a
// symlink during the walk, the open fails and the item is reported, so no
// change reaches the symlink's target.
+ (void)markItemNamed:(const char *)name
          inDirectory:(int)parentFD
                 path:(NSString *)path
                value:(NSData *)value
               failed:(NSMutableArray<NSString *> *)failed {
    struct stat st;
    if (fstatat(parentFD, name, &st, AT_SYMLINK_NOFOLLOW) != 0) {
        [failed addObject:path];
        return;
    }
    if (NAWillOpenItemHandler) NAWillOpenItemHandler(path);

    BOOL isLink = S_ISLNK(st.st_mode);
    BOOL isDirectory = S_ISDIR(st.st_mode);
    int flags = isLink ? (O_RDONLY | O_SYMLINK)
              : isDirectory ? (O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
              : (O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
    mode_t originalMode = st.st_mode & 07777;
    BOOL addedReadAccess = NO;

    int fd = openat(parentFD, name, flags);
    if (fd < 0 && errno == EACCES && !isLink) {
        // An unreadable directory gets owner rwx (the access
        // NALibarchiveExtractor gives its output); an unreadable file gets
        // owner read until it is marked. AT_SYMLINK_NOFOLLOW changes only a
        // symlink itself if the item has been replaced by one.
        mode_t added = isDirectory ? 0700 : 0400;
        if (fchmodat(parentFD, name, originalMode | added, AT_SYMLINK_NOFOLLOW) == 0) {
            addedReadAccess = !isDirectory;
            fd = openat(parentFD, name, flags);
        }
    }
    if (fd < 0) {
        [failed addObject:path];
        return;
    }

    struct stat opened;
    if (fstat(fd, &opened) != 0) {
        [failed addObject:path];
        close(fd);
        return;
    }
    isDirectory = S_ISDIR(opened.st_mode);

    // Setting an extended attribute needs write permission on the item
    // itself, which read-only files and directories from archives often lack.
    BOOL marked = fsetxattr(fd, kQuarantineAttribute, value.bytes, value.length, 0, 0) == 0;
    if (!marked && errno == EACCES && !S_ISLNK(opened.st_mode) &&
        !(opened.st_mode & S_IWUSR)) {
        mode_t current = opened.st_mode & 07777;
        if (fchmod(fd, current | S_IWUSR) == 0) {
            marked = fsetxattr(fd, kQuarantineAttribute, value.bytes, value.length, 0, 0) == 0;
            fchmod(fd, current);
        }
    }
    if (addedReadAccess) fchmod(fd, originalMode);
    if (!marked) [failed addObject:path];

    if (isDirectory) {
        [self markChildrenOfDirectory:fd path:path value:value failed:failed];
    }
    close(fd);
}

+ (void)markChildrenOfDirectory:(int)fd
                           path:(NSString *)path
                          value:(NSData *)value
                         failed:(NSMutableArray<NSString *> *)failed {
    int listFD = dup(fd);
    DIR *dir = listFD >= 0 ? fdopendir(listFD) : NULL;
    if (!dir) {
        if (listFD >= 0) close(listFD);
        if (![failed containsObject:path]) [failed addObject:path];
        return;
    }

    // Collect the names first, then mark them, so the directory stream is not
    // read while its entries are being changed.
    NSMutableArray<NSData *> *names = [NSMutableArray array];
    struct dirent *entry;
    while ((entry = readdir(dir))) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
        [names addObject:[NSData dataWithBytes:entry->d_name length:strlen(entry->d_name) + 1]];
    }
    closedir(dir);

    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSData *childName in names) {
        NSString *component = [fm stringWithFileSystemRepresentation:childName.bytes
                                                              length:childName.length - 1];
        [self markItemNamed:childName.bytes
                inDirectory:fd
                       path:[path stringByAppendingPathComponent:component]
                      value:value
                     failed:failed];
    }
}

@end
