#import "NALibarchiveExtractor.h"
#import "NALog.h"
#import <archive.h>
#import <archive_entry.h>
#include <sys/stat.h>

NSErrorDomain const NALibarchiveErrorDomain = @"sh.n2o.archiver.libarchive";

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

@implementation NALibarchiveExtractor

#pragma mark - NAExtractorPlugin (class methods)

+ (NSArray<NSString *> *)supportedExtensions {
    return @[
        @"zip", @"rar", @"tar", @"gz", @"tgz", @"bz2", @"tbz2", @"xz", @"txz",
        @"lz", @"lzma", @"zst", @"zstd", @"cab", @"iso", @"cpio",
        @"ar", @"lzh", @"lha", @"warc", @"xar"
    ];
}

// The system type for each supported extension, where one exists. .lz, .zst,
// .zstd and .ar have no system type; files with those extensions are offered
// in the open panel through a type derived from the extension, but the app is
// not registered for them in Info.plist.
+ (NSArray<NSString *> *)supportedUTIs {
    return @[
        @"public.zip-archive",
        @"com.rarlab.rar-archive",
        @"public.tar-archive",
        @"org.gnu.gnu-zip-archive",
        @"org.gnu.gnu-zip-tar-archive",
        @"public.bzip2-archive",
        @"public.tar-bzip2-archive",
        @"org.tukaani.xz-archive",
        @"org.tukaani.tar-xz-archive",
        @"org.tukaani.lzma-archive",
        @"com.microsoft.cab",
        @"public.iso-image",
        @"public.cpio-archive",
        @"cx.c3.lha-archive",
        @"org.archive.warc-archive",
        @"com.apple.xar-archive"
    ];
}

+ (BOOL)canHandleFileAtURL:(NSURL *)url {
    struct archive *a = NANewArchiveReader();

    BOOL result = NO;
    if (archive_read_open_filename(a, url.fileSystemRepresentation, 10240)
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

- (BOOL)extractArchiveAtURL:(NSURL *)archiveURL
           toDestinationURL:(NSURL *)destinationURL
                   progress:(NSProgress *)progress
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
    if (!realpath(destinationURL.fileSystemRepresentation, resolvedDest)) {
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                         code:errno
                                     userInfo:@{NSURLErrorKey: destinationURL}];
        }
        archive_read_free(a);
        archive_write_free(ext);
        return NO;
    }

    int r = archive_read_open_filename(a, archiveURL.fileSystemRepresentation, 10240);
    if (r != ARCHIVE_OK) {
        [self setError:error fromArchive:a code:NALibarchiveErrorOpen];
        archive_read_free(a);
        archive_write_free(ext);
        return NO;
    }

    // Progress counts bytes of the archive file read so far, which needs no
    // separate pass over the archive.
    struct stat st;
    progress.totalUnitCount =
        stat(archiveURL.fileSystemRepresentation, &st) == 0 ? st.st_size : 0;

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
            [self setError:error fromArchive:a code:NALibarchiveErrorReadHeader];
            success = NO;
            break;
        }
        if (r == ARCHIVE_WARN) {
            os_log(NALog(), "header read warning: %{public}s", archive_error_string(a));
        }
        entryCount++;

        if (progress.isCancelled) {
            [self setCancelledError:error];
            success = NO;
            break;
        }

        if (NAIsUncompressedRaw(a)) {
            [self setError:error
               description:NSLocalizedString(@"Unrecognized archive format",
                                             @"Error for a file that is not an archive")
                      code:NALibarchiveErrorUnrecognizedFormat];
            success = NO;
            break;
        }

        // The raw format names its single entry "data"; use the archive's
        // name without its compression extension instead.
        if ((archive_format(a) & ARCHIVE_FORMAT_BASE_MASK) == ARCHIVE_FORMAT_RAW) {
            NSString *name = archiveURL.URLByDeletingPathExtension.lastPathComponent;
            archive_entry_copy_pathname(entry, name.fileSystemRepresentation);
        }

        const char *entryPath = archive_entry_pathname(entry);
        if (!entryPath) {
            [self setError:error
               description:NSLocalizedString(@"An entry in the archive has no readable name.",
                                             @"Error for an entry without a name")
                      code:NALibarchiveErrorEntryName];
            success = NO;
            break;
        }
        archive_entry_set_perm(entry, [self sanitizedPermissionsForEntry:entry]);

        // Rewrite the entry pathname, and the hardlink target if any, to be
        // under the destination. Hardlink targets are otherwise resolved
        // against the process working directory.
        [self rebaseEntry:entry underDirectory:resolvedDest];
        progress.fileURL = [NSURL fileURLWithFileSystemRepresentation:archive_entry_pathname(entry)
                                                          isDirectory:archive_entry_filetype(entry) == AE_IFDIR
                                                        relativeToURL:nil];

        r = archive_write_header(ext, entry);
        if (r < ARCHIVE_WARN) {
            // Includes entries rejected by the SECURE_* checks above.
            [self setError:error fromArchive:ext code:NALibarchiveErrorWriteEntry];
            success = NO;
            break;
        }
        if (r != ARCHIVE_OK) {
            os_log(NALog(), "header write warning: %{public}s", archive_error_string(ext));
        }

        // Data is read for every entry except directories, including entries
        // without a stored size (such as raw) or without a file type in their
        // mode. The RAR5 reader fails when asked for a directory's data.
        r = archive_entry_filetype(entry) != AE_IFDIR
            ? [self copyDataFromArchive:a toWriter:ext progress:progress]
            : ARCHIVE_OK;
        if (r != ARCHIVE_OK) {
            if (progress.isCancelled) {
                [self setCancelledError:error];
            } else {
                [self setError:error fromArchive:a code:NALibarchiveErrorData];
            }
            success = NO;
            break;
        }
        archive_write_finish_entry(ext);

        [self reportProgressFromArchive:a progress:progress];
    }

    // The cancel may arrive after the last entry; report it so the caller
    // treats the output as cancelled.
    if (success && progress.isCancelled) {
        [self setCancelledError:error];
        success = NO;
    }

    if (success && entryCount == 0) {
        [self setError:error
           description:NSLocalizedString(@"The archive contains no files.",
                                         @"Error for an archive without entries")
                  code:NALibarchiveErrorNoEntries];
        success = NO;
    }

    if (success) {
        progress.completedUnitCount = progress.totalUnitCount;
    }

    archive_read_free(a);
    archive_write_free(ext);
    return success;
}

#pragma mark - NAExtractorPlugin (optional: list contents)

- (NSArray<NSString *> *)contentsOfArchiveAtURL:(NSURL *)url
                                          error:(NSError **)error {
    struct archive *a = NANewArchiveReader();

    int r = archive_read_open_filename(a, url.fileSystemRepresentation, 10240);
    if (r != ARCHIVE_OK) {
        [self setError:error fromArchive:a code:NALibarchiveErrorOpen];
        archive_read_free(a);
        return nil;
    }

    NSMutableArray<NSString *> *entries = [NSMutableArray array];
    struct archive_entry *entry;
    for (;;) {
        r = archive_read_next_header(a, &entry);
        if (r == ARCHIVE_EOF) break;
        if (r != ARCHIVE_OK && r != ARCHIVE_WARN) {
            [self setError:error fromArchive:a code:NALibarchiveErrorReadHeader];
            archive_read_free(a);
            return nil;
        }
        if (NAIsUncompressedRaw(a)) {
            [self setError:error
               description:NSLocalizedString(@"Unrecognized archive format",
                                             @"Error for a file that is not an archive")
                      code:NALibarchiveErrorUnrecognizedFormat];
            archive_read_free(a);
            return nil;
        }
        if ((archive_format(a) & ARCHIVE_FORMAT_BASE_MASK) == ARCHIVE_FORMAT_RAW) {
            [entries addObject:url.URLByDeletingPathExtension.lastPathComponent];
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
                  toWriter:(struct archive *)aw
                  progress:(NSProgress *)progress {
    const void *buff;
    size_t size;
    la_int64_t offset;

    for (;;) {
        if (progress.isCancelled) return ARCHIVE_FAILED;

        int r = archive_read_data_block(ar, &buff, &size, &offset);
        if (r == ARCHIVE_EOF) return ARCHIVE_OK;
        if (r != ARCHIVE_OK) return r;

        r = (int)archive_write_data_block(aw, buff, size, offset);
        if (r != ARCHIVE_OK) {
            os_log_error(NALog(), "write error: %{public}s", archive_error_string(aw));
            return r;
        }

        [self reportProgressFromArchive:ar progress:progress];
    }
}

// Sets completedUnitCount to the bytes of the archive file read so far, capped
// at the file size and never decreasing.
- (void)reportProgressFromArchive:(struct archive *)ar progress:(NSProgress *)progress {
    int64_t read = MIN(archive_filter_bytes(ar, -1), progress.totalUnitCount);
    if (read > progress.completedUnitCount) progress.completedUnitCount = read;
}

- (void)setCancelledError:(NSError **)error {
    if (!error) return;
    *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                 code:NSUserCancelledError
                             userInfo:nil];
}

- (void)setError:(NSError **)error
     fromArchive:(struct archive *)a
            code:(NALibarchiveError)code {
    const char *msg = archive_error_string(a);
    [self setError:error
       description:msg ? [NSString stringWithUTF8String:msg]
                       : NSLocalizedString(@"Unknown archive error",
                                           @"Error when libarchive gives no message")
              code:code];
}

- (void)setError:(NSError **)error
     description:(NSString *)description
            code:(NALibarchiveError)code {
    if (!error) return;
    *error = [NSError errorWithDomain:NALibarchiveErrorDomain
                                 code:code
                             userInfo:@{NSLocalizedDescriptionKey: description}];
}

@end
