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
    [self setQuarantine:value onPath:rootPath failed:failed];

    // enumeratorAtPath: does not descend into symlinked directories.
    for (NSString *relativePath in [[NSFileManager defaultManager] enumeratorAtPath:rootPath]) {
        [self setQuarantine:value
                     onPath:[rootPath stringByAppendingPathComponent:relativePath]
                     failed:failed];
    }

    if (failed.count == 0) return YES;

    if (error) {
        NSString *description = failed.count == 1
            ? @"1 extracted item could not be marked as downloaded from the "
              @"internet, so macOS will not check it before it opens."
            : [NSString stringWithFormat:
                @"%lu extracted items could not be marked as downloaded from the "
                @"internet, so macOS will not check them before they open.",
                (unsigned long)failed.count];
        *error = [NSError errorWithDomain:NAQuarantineErrorDomain
                                     code:1
                                 userInfo:@{NSLocalizedDescriptionKey: description,
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
