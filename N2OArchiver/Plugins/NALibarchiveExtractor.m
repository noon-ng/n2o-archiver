#import "NALibarchiveExtractor.h"
#import <archive.h>
#import <archive_entry.h>
#include <sys/stat.h>

static NSString *const NALibarchiveErrorDomain = @"sh.n2o.archiver.libarchive";

// Every format archive_read_support_format_all enables except mtree, which
// accepts most text files and can reference files elsewhere on disk, plus raw,
// which reads a single compressed file (.gz, .bz2, .xz without tar).
static struct archive *NANewArchiveReader(void) {
    struct archive *a = archive_read_new();
    archive_read_support_filter_all(a);
    archive_read_support_format_7zip(a);
    archive_read_support_format_ar(a);
    archive_read_support_format_cab(a);
    archive_read_support_format_cpio(a);
    archive_read_support_format_empty(a);
    archive_read_support_format_iso9660(a);
    archive_read_support_format_lha(a);
    archive_read_support_format_rar(a);
    archive_read_support_format_rar5(a);
    archive_read_support_format_tar(a);
    archive_read_support_format_warc(a);
    archive_read_support_format_xar(a);
    archive_read_support_format_zip(a);
    archive_read_support_format_raw(a);
    return a;
}

// The raw format matches any input; it only describes a real archive when a
// compression filter was detected in front of it.
static BOOL NAIsUncompressedRaw(struct archive *a) {
    return (archive_format(a) & ARCHIVE_FORMAT_BASE_MASK) == ARCHIVE_FORMAT_RAW
        && archive_filter_count(a) <= 1;
}

@interface NALibarchiveExtractor ()
@property (atomic, assign) BOOL cancelled;
@end

@implementation NALibarchiveExtractor {
    // Progress state for the extraction in progress.
    NAExtractionProgressBlock _progressBlock;
    int64_t _archiveSize;
    double _lastReportedFraction;
    NSString *_currentEntryName;
}

#pragma mark - NAExtractorPlugin (class methods)

+ (NSArray<NSString *> *)supportedExtensions {
    return @[
        @"zip", @"tar", @"gz", @"tgz", @"bz2", @"tbz2", @"xz", @"txz",
        @"lz", @"lzma", @"zst", @"zstd", @"cab", @"iso", @"cpio",
        @"ar", @"lzh", @"lha", @"warc"
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
    struct archive *a = NANewArchiveReader();

    BOOL result = NO;
    if (archive_read_open_filename(a, path.fileSystemRepresentation, 10240)
        == ARCHIVE_OK) {
        // "empty" bids on any zero-byte file and raw on any input, so a
        // successful open alone does not indicate an archive. An archive must
        // also yield an entry: ARCHIVE_EOF here means no entries (for example
        // 1024 zero bytes read as an empty tar).
        struct archive_entry *entry;
        int r = archive_read_next_header(a, &entry);
        int format = archive_format(a) & ARCHIVE_FORMAT_BASE_MASK;
        result = (r == ARCHIVE_OK || r == ARCHIVE_WARN)
              && format != ARCHIVE_FORMAT_EMPTY
              && !NAIsUncompressedRaw(a);
    }
    archive_read_free(a);

    return result;
}

#pragma mark - NAExtractorPlugin (extraction)

- (BOOL)extractArchiveAtPath:(NSString *)archivePath
               toDestination:(NSString *)destPath
                    progress:(NAExtractionProgressBlock)progressBlock
                       error:(NSError **)error {
    struct archive *a = NANewArchiveReader();
    struct archive *ext = archive_write_disk_new();

    // Entry paths are rewritten to absolute paths under destPath, so
    // SECURE_NOABSOLUTEPATHS cannot be used. SECURE_NODOTDOT rejects entries
    // (and hardlink targets) containing "..", and SECURE_SYMLINKS rejects
    // entries whose path passes through a symlink.
    //
    // ARCHIVE_EXTRACT_PERM, _ACL and _FFLAGS are not set: the archive does not
    // decide file modes beyond sanitizedPermissionsForEntry:, ACLs or flags
    // such as uchg. Without _PERM, libarchive also applies the umask.
    int flags = ARCHIVE_EXTRACT_TIME
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

    // Progress is the share of the archive file read so far, which needs no
    // separate pass over the archive.
    struct stat st;
    _archiveSize = stat(archivePath.fileSystemRepresentation, &st) == 0 ? st.st_size : 0;
    _progressBlock = progressBlock;
    _lastReportedFraction = -1;
    _currentEntryName = @"";

    struct archive_entry *entry;
    BOOL success = YES;
    NSUInteger entryCount = 0;

    for (;;) {
        r = archive_read_next_header(a, &entry);
        if (r == ARCHIVE_EOF) break;
        // ARCHIVE_WARN covers recoverable problems, such as an entry name that
        // cannot be converted to the current locale; the name's bytes are still
        // available and are used. Any other result means the rest of the
        // archive cannot be read, which is reported rather than treated as the
        // end of the archive.
        if (r != ARCHIVE_OK && r != ARCHIVE_WARN) {
            [self setError:error fromArchive:a code:5];
            success = NO;
            break;
        }
        if (r == ARCHIVE_WARN) {
            NSLog(@"N2OArchiver: header read warning: %s", archive_error_string(a));
        }
        entryCount++;

        if (self.cancelled) {
            [self setCancelledError:error];
            success = NO;
            break;
        }

        if (NAIsUncompressedRaw(a)) {
            [self setError:error description:@"Unrecognized archive format" code:4];
            success = NO;
            break;
        }

        // The raw format names its single entry "data"; use the archive's
        // name without its compression extension instead.
        if ((archive_format(a) & ARCHIVE_FORMAT_BASE_MASK) == ARCHIVE_FORMAT_RAW) {
            NSString *name = archivePath.lastPathComponent.stringByDeletingPathExtension;
            archive_entry_copy_pathname(entry, name.fileSystemRepresentation);
        }

        const char *entryPath = archive_entry_pathname(entry);
        if (!entryPath) {
            [self setError:error description:@"An entry in the archive has no readable name."
                      code:6];
            success = NO;
            break;
        }
        _currentEntryName = (entryPath ? [NSString stringWithUTF8String:entryPath] : nil)
                            .lastPathComponent ?: @"";

        archive_entry_set_perm(entry, [self sanitizedPermissionsForEntry:entry]);

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
        }
        if (r != ARCHIVE_OK) {
            NSLog(@"N2OArchiver: header write warning: %s", archive_error_string(ext));
        }

        // Entries without a stored size (such as raw) still carry data, so
        // data is copied for every entry; directories return EOF at once.
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
        archive_write_finish_entry(ext);

        [self reportProgressFromArchive:a force:YES];
    }

    // The cancel may arrive after the last entry; report it so the caller
    // treats the output as cancelled.
    if (success && self.cancelled) {
        [self setCancelledError:error];
        success = NO;
    }

    if (success && entryCount == 0) {
        [self setError:error description:@"The archive contains no files." code:7];
        success = NO;
    }

    if (success && progressBlock) {
        progressBlock(1.0, _currentEntryName);
    }

    _progressBlock = nil;
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
    struct archive *a = NANewArchiveReader();

    int r = archive_read_open_filename(a, path.fileSystemRepresentation, 10240);
    if (r != ARCHIVE_OK) {
        [self setError:error fromArchive:a code:1];
        archive_read_free(a);
        return nil;
    }

    NSMutableArray<NSString *> *entries = [NSMutableArray array];
    struct archive_entry *entry;
    for (;;) {
        r = archive_read_next_header(a, &entry);
        if (r == ARCHIVE_EOF) break;
        if (r != ARCHIVE_OK && r != ARCHIVE_WARN) {
            [self setError:error fromArchive:a code:5];
            archive_read_free(a);
            return nil;
        }
        if (NAIsUncompressedRaw(a)) {
            [self setError:error description:@"Unrecognized archive format" code:4];
            archive_read_free(a);
            return nil;
        }
        if ((archive_format(a) & ARCHIVE_FORMAT_BASE_MASK) == ARCHIVE_FORMAT_RAW) {
            [entries addObject:path.lastPathComponent.stringByDeletingPathExtension];
        } else {
            const char *name = archive_entry_pathname(entry);
            if (name) {
                [entries addObject:[NSString stringWithUTF8String:name]];
            }
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

// Drops group and other write and the setuid, setgid and sticky bits, and
// gives the owner read access to files and full access to directories, so the
// output cannot be modified by other accounts and can always be listed,
// quarantined and removed.
- (mode_t)sanitizedPermissionsForEntry:(struct archive_entry *)entry {
    mode_t perm = archive_entry_perm(entry) & 0755;
    perm |= archive_entry_filetype(entry) == AE_IFDIR ? 0700 : 0400;
    return perm;
}

- (NSMutableData *)joinPath:(const char *)directory with:(const char *)name {
    NSMutableData *data = [NSMutableData dataWithBytes:directory
                                                length:strlen(directory)];
    [data appendBytes:"/" length:1];
    [data appendBytes:name length:strlen(name) + 1];
    return data;
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

        [self reportProgressFromArchive:ar force:NO];
    }
}

// Reports the share of the archive file consumed so far. Within an entry,
// reports only after at least 1% more has been read, so a large file gives
// steady updates without one callback per data block.
- (void)reportProgressFromArchive:(struct archive *)ar force:(BOOL)force {
    if (!_progressBlock || _archiveSize <= 0) return;

    double fraction = (double)archive_filter_bytes(ar, -1) / (double)_archiveSize;
    if (fraction > 1.0) fraction = 1.0;
    if (fraction < _lastReportedFraction) return;
    if (!force && fraction - _lastReportedFraction < 0.01) return;

    _lastReportedFraction = fraction;
    _progressBlock(fraction, _currentEntryName);
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
    const char *msg = archive_error_string(a);
    [self setError:error
       description:msg ? [NSString stringWithUTF8String:msg] : @"Unknown archive error"
              code:code];
}

- (void)setError:(NSError **)error
     description:(NSString *)description
            code:(NSInteger)code {
    if (!error) return;
    *error = [NSError errorWithDomain:NALibarchiveErrorDomain
                                 code:code
                             userInfo:@{NSLocalizedDescriptionKey:
                                            description ?: @"Unknown archive error"}];
}

@end
