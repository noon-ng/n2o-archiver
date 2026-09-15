#import "NAQuarantine.h"
#include <sys/stat.h>
#include <sys/xattr.h>

NSString *const NAQuarantineErrorDomain = @"sh.n2o.archiver.quarantine";

static const char *const kQuarantineAttribute = "com.apple.quarantine";

@implementation NAQuarantine

+ (BOOL)copyQuarantineFromPath:(NSString *)sourcePath
                  toTreeAtPath:(NSString *)rootPath
                         error:(NSError **)error {
    NSData *value = [self quarantineValueAtPath:sourcePath];
    if (!value) return YES;

    NSMutableArray<NSString *> *failed = [NSMutableArray array];
    [self markTreeAtPath:rootPath value:value failed:failed];

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

// Marks path and, for a directory, everything below it. Symlinks are marked
// themselves and not followed. A directory that cannot be listed is given
// owner read, write and search permission (the access NALibarchiveExtractor
// already gives its output) and is reported as a failure if it still cannot be
// listed, instead of being skipped.
+ (void)markTreeAtPath:(NSString *)path
                 value:(NSData *)value
                failed:(NSMutableArray<NSString *> *)failed {
    [self setQuarantine:value onPath:path failed:failed];

    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) != 0 || !S_ISDIR(st.st_mode)) return;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *children = [fm contentsOfDirectoryAtPath:path error:nil];
    if (!children && (st.st_mode & 0700) != 0700 &&
        chmod(path.fileSystemRepresentation, (st.st_mode & 07777) | 0700) == 0) {
        children = [fm contentsOfDirectoryAtPath:path error:nil];
    }
    if (!children) {
        if (![failed containsObject:path]) [failed addObject:path];
        return;
    }

    for (NSString *child in children) {
        [self markTreeAtPath:[path stringByAppendingPathComponent:child]
                       value:value
                      failed:failed];
    }
}

+ (void)setQuarantine:(NSData *)value
               onPath:(NSString *)path
               failed:(NSMutableArray<NSString *> *)failed {
    const char *p = path.fileSystemRepresentation;
    if (setxattr(p, kQuarantineAttribute, value.bytes, value.length, 0, XATTR_NOFOLLOW) == 0) {
        return;
    }

    // Setting an extended attribute needs write permission on the item itself,
    // which read-only files and directories from archives often lack.
    struct stat st;
    if (errno == EACCES && lstat(p, &st) == 0 && !S_ISLNK(st.st_mode) &&
        !(st.st_mode & S_IWUSR) && chmod(p, (st.st_mode & 07777) | S_IWUSR) == 0) {
        int result = setxattr(p, kQuarantineAttribute, value.bytes, value.length,
                              0, XATTR_NOFOLLOW);
        chmod(p, st.st_mode & 07777);
        if (result == 0) return;
    }

    [failed addObject:path];
}

@end
