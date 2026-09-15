#import "NALibarchiveExtractor.h"
#import <archive.h>
#import <archive_entry.h>

static NSString *const NALibarchiveErrorDomain = @"sh.n2o.archiver.libarchive";

@interface NALibarchiveExtractor ()
@property (atomic, assign) BOOL cancelled;
@end

@implementation NALibarchiveExtractor

#pragma mark - NAExtractorPlugin (class methods)

+ (NSArray<NSString *> *)supportedExtensions {
    return @[
        @"zip", @"tar", @"gz", @"tgz", @"bz2", @"tbz2", @"xz", @"txz",
        @"lz", @"lzma", @"zst", @"zstd", @"cab", @"iso", @"cpio",
        @"ar", @"lzh", @"lha", @"warc",
        @"tar.gz", @"tar.bz2", @"tar.xz", @"tar.lz", @"tar.zst"
    ];
}

+ (NSArray<NSString *> *)supportedUTIs {
    return @[
        @"public.zip-archive",
        @"public.tar-archive",
        @"org.gnu.gnu-zip-archive",
        @"public.bzip2-archive",
        @"org.tukaani.xz-archive",
        @"com.apple.xar-archive",
        @"public.cpio-archive",
        @"public.iso-image"
    ];
}

+ (BOOL)canHandleFileAtPath:(NSString *)path {
    struct archive *a = archive_read_new();
    archive_read_support_filter_all(a);
    archive_read_support_format_all(a);

    BOOL result = NO;
    if (archive_read_open_filename(a, path.fileSystemRepresentation, 10240)
        == ARCHIVE_OK) {
        // mtree bids on most text files and "empty" on any zero-byte file, so
        // a successful open alone does not indicate an archive. Reading the
        // first header rejects text that is not a valid mtree spec; mtree and
        // empty are then excluded explicitly.
        struct archive_entry *entry;
        int r = archive_read_next_header(a, &entry);
        int format = archive_format(a) & ARCHIVE_FORMAT_BASE_MASK;
        result = r >= ARCHIVE_WARN
              && format != ARCHIVE_FORMAT_MTREE
              && format != ARCHIVE_FORMAT_EMPTY;
    }
    archive_read_free(a);

    return result;
}

#pragma mark - NAExtractorPlugin (extraction)

- (BOOL)extractArchiveAtPath:(NSString *)archivePath
               toDestination:(NSString *)destPath
                    progress:(NAExtractionProgressBlock)progressBlock
                       error:(NSError **)error {
    struct archive *a = archive_read_new();
    struct archive *ext = archive_write_disk_new();

    archive_read_support_filter_all(a);
    archive_read_support_format_all(a);

    // Entry paths are rewritten to absolute paths under destPath, so
    // SECURE_NOABSOLUTEPATHS cannot be used. SECURE_NODOTDOT rejects entries
    // (and hardlink targets) containing "..", and SECURE_SYMLINKS rejects
    // entries whose path passes through a symlink.
    int flags = ARCHIVE_EXTRACT_TIME
              | ARCHIVE_EXTRACT_PERM
              | ARCHIVE_EXTRACT_ACL
              | ARCHIVE_EXTRACT_FFLAGS
              | ARCHIVE_EXTRACT_SECURE_NODOTDOT
              | ARCHIVE_EXTRACT_SECURE_SYMLINKS;
    archive_write_disk_set_options(ext, flags);
    archive_write_disk_set_standard_lookup(ext);

    // SECURE_SYMLINKS checks every component of the absolute path, so the
    // destination itself must not contain symlinks (e.g. /var -> /private/var).
    char resolvedDest[PATH_MAX];
    if (!realpath(destPath.fileSystemRepresentation, resolvedDest)) {
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                         code:errno
                                     userInfo:@{NSFilePathErrorKey: destPath}];
        }
        archive_read_free(a);
        archive_write_free(ext);
        return NO;
    }

    int r = archive_read_open_filename(a, archivePath.fileSystemRepresentation, 10240);
    if (r != ARCHIVE_OK) {
        [self setError:error fromArchive:a code:1];
        archive_read_free(a);
        archive_write_free(ext);
        return NO;
    }

    // Determine total size for progress reporting.
    int64_t totalSize = [self totalSizeOfArchive:archivePath];
    int64_t extractedSize = 0;

    struct archive_entry *entry;
    BOOL success = YES;

    while (archive_read_next_header(a, &entry) == ARCHIVE_OK) {
        if (self.cancelled) {
            [self setCancelledError:error];
            success = NO;
            break;
        }

        // Rewrite the entry pathname, and the hardlink target if any, to be
        // under the destination. Hardlink targets are otherwise resolved
        // against the process working directory.
        [self rebaseEntry:entry underDirectory:resolvedDest];

        r = archive_write_header(ext, entry);
        if (r < ARCHIVE_WARN) {
            // Includes entries rejected by the SECURE_* checks above.
            [self setError:error fromArchive:ext code:3];
            success = NO;
            break;
        } else if (r != ARCHIVE_OK) {
            NSLog(@"N2OArchiver: header write error: %s", archive_error_string(ext));
        } else if (archive_entry_size(entry) > 0) {
            r = [self copyDataFromArchive:a toWriter:ext];
            if (r != ARCHIVE_OK) {
                if (self.cancelled) {
                    [self setCancelledError:error];
                } else {
                    [self setError:error fromArchive:a code:2];
                }
                success = NO;
                break;
            }
        }
        archive_write_finish_entry(ext);

        extractedSize += archive_entry_size(entry);
        if (progressBlock && totalSize > 0) {
            double fraction = (double)extractedSize / (double)totalSize;
            if (fraction > 1.0) fraction = 1.0;
            NSString *name = [NSString stringWithUTF8String:
                              archive_entry_pathname(entry)];
            progressBlock(fraction, name.lastPathComponent);
        }
    }

    // The cancel may arrive after the last entry; report it so the caller
    // treats the output as cancelled.
    if (success && self.cancelled) {
        [self setCancelledError:error];
        success = NO;
    }

    archive_read_free(a);
    archive_write_free(ext);
    return success;
}

- (void)cancelExtraction {
    self.cancelled = YES;
}

#pragma mark - NAExtractorPlugin (optional: list contents)

- (NSArray<NSString *> *)contentsOfArchiveAtPath:(NSString *)path
                                           error:(NSError **)error {
    struct archive *a = archive_read_new();
    archive_read_support_filter_all(a);
    archive_read_support_format_all(a);

    int r = archive_read_open_filename(a, path.fileSystemRepresentation, 10240);
    if (r != ARCHIVE_OK) {
        [self setError:error fromArchive:a code:1];
        archive_read_free(a);
        return nil;
    }

    NSMutableArray<NSString *> *entries = [NSMutableArray array];
    struct archive_entry *entry;
    while (archive_read_next_header(a, &entry) == ARCHIVE_OK) {
        const char *name = archive_entry_pathname(entry);
        if (name) {
            [entries addObject:[NSString stringWithUTF8String:name]];
        }
        archive_read_data_skip(a);
    }

    archive_read_free(a);
    return entries;
}

#pragma mark - Private

- (void)rebaseEntry:(struct archive_entry *)entry
     underDirectory:(const char *)directory {
    // Built from raw bytes: entry names are not guaranteed to be UTF-8.
    // A leading "/" in the entry name yields "//", which libarchive collapses.
    const char *pathname = archive_entry_pathname(entry);
    if (pathname) {
        NSMutableData *full = [self joinPath:directory with:pathname];
        archive_entry_set_pathname(entry, full.bytes);
    }

    const char *hardlink = archive_entry_hardlink(entry);
    if (hardlink) {
        NSMutableData *full = [self joinPath:directory with:hardlink];
        archive_entry_set_hardlink(entry, full.bytes);
    }
}

- (NSMutableData *)joinPath:(const char *)directory with:(const char *)name {
    NSMutableData *data = [NSMutableData dataWithBytes:directory
                                                length:strlen(directory)];
    [data appendBytes:"/" length:1];
    [data appendBytes:name length:strlen(name) + 1];
    return data;
}

- (int64_t)totalSizeOfArchive:(NSString *)archivePath {
    struct archive *a = archive_read_new();
    archive_read_support_filter_all(a);
    archive_read_support_format_all(a);

    if (archive_read_open_filename(a, archivePath.fileSystemRepresentation, 10240)
        != ARCHIVE_OK) {
        archive_read_free(a);
        return -1;
    }

    int64_t total = 0;
    struct archive_entry *entry;
    while (archive_read_next_header(a, &entry) == ARCHIVE_OK) {
        // This pass decompresses the whole archive; stop early on cancel.
        if (self.cancelled) break;
        total += archive_entry_size(entry);
        archive_read_data_skip(a);
    }

    archive_read_free(a);
    return total;
}

- (int)copyDataFromArchive:(struct archive *)ar
                  toWriter:(struct archive *)aw {
    const void *buff;
    size_t size;
    la_int64_t offset;

    for (;;) {
        if (self.cancelled) return ARCHIVE_FAILED;

        int r = archive_read_data_block(ar, &buff, &size, &offset);
        if (r == ARCHIVE_EOF) return ARCHIVE_OK;
        if (r != ARCHIVE_OK) return r;

        r = (int)archive_write_data_block(aw, buff, size, offset);
        if (r != ARCHIVE_OK) {
            NSLog(@"N2OArchiver: write error: %s", archive_error_string(aw));
            return r;
        }
    }
}

- (void)setCancelledError:(NSError **)error {
    if (!error) return;
    *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                 code:NSUserCancelledError
                             userInfo:nil];
}

- (void)setError:(NSError **)error
     fromArchive:(struct archive *)a
            code:(NSInteger)code {
    if (!error) return;
    const char *msg = archive_error_string(a);
    NSString *desc = msg ? [NSString stringWithUTF8String:msg]
                         : @"Unknown archive error";
    *error = [NSError errorWithDomain:NALibarchiveErrorDomain
                                 code:code
                             userInfo:@{NSLocalizedDescriptionKey: desc}];
}

@end
