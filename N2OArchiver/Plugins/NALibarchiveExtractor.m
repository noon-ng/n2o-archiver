#import "NALibarchiveExtractor.h"
#import <archive.h>
#import <archive_entry.h>

static NSString *const NALibarchiveErrorDomain = @"sh.n2o.archiver.libarchive";

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

    int r = archive_read_open_filename(a, path.fileSystemRepresentation, 10240);
    archive_read_free(a);

    return (r == ARCHIVE_OK);
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

    int flags = ARCHIVE_EXTRACT_TIME
              | ARCHIVE_EXTRACT_PERM
              | ARCHIVE_EXTRACT_ACL
              | ARCHIVE_EXTRACT_FFLAGS;
    archive_write_disk_set_options(ext, flags);
    archive_write_disk_set_standard_lookup(ext);

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
        // Rewrite entry pathname to be under destPath.
        const char *entryPath = archive_entry_pathname(entry);
        NSString *fullPath = [destPath stringByAppendingPathComponent:
                              [NSString stringWithUTF8String:entryPath]];
        archive_entry_set_pathname(entry, fullPath.fileSystemRepresentation);

        r = archive_write_header(ext, entry);
        if (r != ARCHIVE_OK) {
            NSLog(@"N2OArchiver: header write error: %s", archive_error_string(ext));
        } else if (archive_entry_size(entry) > 0) {
            r = [self copyDataFromArchive:a toWriter:ext];
            if (r != ARCHIVE_OK) {
                [self setError:error fromArchive:a code:2];
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

    archive_read_free(a);
    archive_write_free(ext);
    return success;
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
