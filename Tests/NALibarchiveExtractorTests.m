#import "NATestCase.h"
#import "NATestFixtures.h"
#import "Plugins/NALibarchiveExtractor.h"
#import <archive.h>
#import <archive_entry.h>
#include <sys/acl.h>
#include <sys/stat.h>

@interface NALibarchiveExtractorTests : NATestCase
@property (nonatomic, strong) NALibarchiveExtractor *extractor;
@property (nonatomic, copy) NSString *destDir;
@end

@implementation NALibarchiveExtractorTests

- (void)setUp {
    [super setUp];
    self.extractor = [[NALibarchiveExtractor alloc] init];
    self.destDir = [NSTemporaryDirectory()
        stringByAppendingPathComponent:
            [NSString stringWithFormat:@"n2o-extract-%u", arc4random()]];
    [[NSFileManager defaultManager] createDirectoryAtPath:self.destDir
                              withIntermediateDirectories:YES
                                               attributes:nil error:nil];
}

- (void)tearDown {
    // Clear flags and restore owner access left by archives under test.
    NSFileManager *fm = [NSFileManager defaultManager];
    chmod(self.destDir.fileSystemRepresentation, 0755);
    for (NSString *item in [fm enumeratorAtPath:self.destDir]) {
        const char *path = [self.destDir stringByAppendingPathComponent:item].fileSystemRepresentation;
        struct stat st;
        if (lstat(path, &st) == 0 && !S_ISLNK(st.st_mode)) {
            chflags(path, 0);
            chmod(path, (st.st_mode & 0777) | (S_ISDIR(st.st_mode) ? 0700 : 0600));
        }
    }
    [fm removeItemAtPath:self.destDir error:nil];
    [super tearDown];
}

#pragma mark - Format tests

- (void)testExtractZip {
    [self assertExtractsFixture:@"test.zip"];
}

- (void)testExtractTar {
    [self assertExtractsFixture:@"test.tar"];
}

- (void)testExtractTarGz {
    [self assertExtractsFixture:@"test.tar.gz"];
}

- (void)testExtractTarBz2 {
    [self assertExtractsFixture:@"test.tar.bz2"];
}

- (void)testExtractTarXz {
    NSString *path = [NATestFixtures pathForFixture:@"test.tar.xz"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return; // xz not available
    [self assertExtractsFixture:@"test.tar.xz"];
}

- (void)testExtractRar {
    [self assertExtractsFixture:@"test.rar"];
}

- (void)testDiskImageNamedRarIsNotExtracted {
    NSString *renamed = [NATestFixtures pathForFixture:@"disk-image-renamed.rar"];
    [[NSFileManager defaultManager] copyItemAtPath:[NATestFixtures pathForFixture:@"disk-image.dmg"]
                                            toPath:renamed error:nil];
    NSError *error = nil;
    BOOL ok = [self.extractor extractArchiveAtPath:renamed toDestination:self.destDir
                                          progress:nil error:&error];
    [[NSFileManager defaultManager] removeItemAtPath:renamed error:nil];
    NAAssertFalse(ok, @"a disk image named .rar should not be extracted");
    NAAssertEqual([[NSFileManager defaultManager]
                      contentsOfDirectoryAtPath:self.destDir error:nil].count, 0u,
                  @"nothing should be written");
}

- (void)testExtractCpio {
    [self assertExtractsFixture:@"test.cpio"];
}

#pragma mark - Contents listing

- (void)testListContents {
    NSString *path = [NATestFixtures pathForFixture:@"test.zip"];
    NSError *error = nil;
    NSArray<NSString *> *entries = [self.extractor contentsOfArchiveAtPath:path
                                                                    error:&error];
    NAAssertNil(error, @"listing should not error");
    NAAssertNotNil(entries, @"entries should not be nil");
    NAAssertTrue(entries.count >= 3, @"should list at least 3 entries, got %lu",
                 (unsigned long)entries.count);
}

#pragma mark - Progress reporting

- (void)testProgressReported {
    NSString *path = [NATestFixtures pathForFixture:@"test.zip"];
    __block int callCount = 0;
    __block double lastFraction = -1;

    NSError *error = nil;
    BOOL ok = [self.extractor extractArchiveAtPath:path
                                     toDestination:self.destDir
                                          progress:^(double fraction, NSString *entry) {
        callCount++;
        lastFraction = fraction;
    }
                                             error:&error];

    NAAssertTrue(ok, @"extraction should succeed");
    NAAssertTrue(callCount > 0, @"progress block should be called at least once");
    NAAssertTrue(lastFraction > 0, @"final fraction should be > 0");
}

#pragma mark - canHandleFile

- (void)testCanHandleValidArchive {
    NAAssertTrue([NALibarchiveExtractor canHandleFileAtPath:
                  [NATestFixtures pathForFixture:@"test.zip"]]);
}

- (void)testCanHandleRejectsCorrupt {
    NAAssertFalse([NALibarchiveExtractor canHandleFileAtPath:
                   [NATestFixtures pathForFixture:@"corrupt.zip"]]);
}

- (void)testCanHandleRejectsPlainText {
    NSString *path = [NATestFixtures pathForFixture:@"notes.txt"];
    [@"hello\n" writeToFile:path atomically:NO
                  encoding:NSUTF8StringEncoding error:nil];
    NAAssertFalse([NALibarchiveExtractor canHandleFileAtPath:path],
                  @"plain text should not be accepted (libarchive reads it as mtree)");
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
}

- (void)testCanHandleRejectsEmptyFile {
    NSString *path = [NATestFixtures pathForFixture:@"empty.bin"];
    [[NSData data] writeToFile:path atomically:NO];
    NAAssertFalse([NALibarchiveExtractor canHandleFileAtPath:path],
                  @"zero-byte file should not be accepted");
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
}

- (void)testCanHandleRejectsMissing {
    NAAssertFalse([NALibarchiveExtractor canHandleFileAtPath:
                   @"/nonexistent/file.zip"]);
}

#pragma mark - Single compressed files

- (void)testExtractSingleGzipFile {
    [self assertExtractsSingleCompressedFixture:@"plain.txt.gz"];
}

- (void)testExtractSingleBzip2File {
    [self assertExtractsSingleCompressedFixture:@"plain.txt.bz2"];
}

- (void)testExtractSingleXzFile {
    [self assertExtractsSingleCompressedFixture:@"plain.txt.xz"];
}

- (void)testCanHandleSingleCompressedFile {
    NAAssertTrue([NALibarchiveExtractor canHandleFileAtPath:
                  [NATestFixtures pathForFixture:@"plain.txt.gz"]],
                 @"a gzip-compressed text file should be accepted");
}

- (void)testExtractPlainTextFails {
    NSString *path = [NATestFixtures pathForFixture:@"notes.zip"];
    [@"hello\n" writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
    NSError *error = nil;
    BOOL ok = [self.extractor extractArchiveAtPath:path
                                     toDestination:self.destDir
                                          progress:nil
                                             error:&error];
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    NAAssertFalse(ok, @"a text file named .zip should not extract");
    NAAssertEqualObjects([[NSFileManager defaultManager]
                             contentsOfDirectoryAtPath:self.destDir error:nil], @[],
                         @"nothing should be written");
}

- (void)assertExtractsSingleCompressedFixture:(NSString *)name {
    NSError *error = nil;
    BOOL ok = [self.extractor extractArchiveAtPath:[NATestFixtures pathForFixture:name]
                                     toDestination:self.destDir
                                          progress:nil
                                             error:&error];
    NAAssertTrue(ok, @"%@ should extract: %@", name, error.localizedDescription);
    NSString *contents = [NSString stringWithContentsOfFile:
        [self.destDir stringByAppendingPathComponent:@"plain.txt"]
                                                   encoding:NSUTF8StringEncoding error:nil];
    NAAssertEqualObjects(contents, @"plain contents\n",
                         @"%@ should produce plain.txt, directory has %@", name,
                         [[NSFileManager defaultManager] contentsOfDirectoryAtPath:self.destDir error:nil]);
}

#pragma mark - Progress without a size pass

- (void)testProgressIsNondecreasingAndEndsAtOne {
    NSMutableArray<NSNumber *> *fractions = [NSMutableArray array];
    NSError *error = nil;
    BOOL ok = [self.extractor extractArchiveAtPath:[NATestFixtures pathForFixture:@"test.tar.gz"]
                                     toDestination:self.destDir
                                          progress:^(double fraction, NSString *entry) {
        [fractions addObject:@(fraction)];
    }
                                             error:&error];
    NAAssertTrue(ok, @"extraction should succeed: %@", error.localizedDescription);
    NAAssertTrue(fractions.count > 0, @"progress should be reported");
    for (NSUInteger i = 1; i < fractions.count; i++) {
        NAAssertTrue(fractions[i].doubleValue >= fractions[i - 1].doubleValue,
                     @"progress should not go backwards: %@", fractions);
    }
    NAAssertTrue(fractions.lastObject.doubleValue == 1.0,
                 @"last progress should be 1.0: %@", fractions);
}

- (void)testSupportedExtensionsAreSingleComponents {
    for (NSString *ext in [NALibarchiveExtractor supportedExtensions]) {
        NAAssertTrue([ext rangeOfString:@"."].location == NSNotFound,
                     @"%@ can never equal -[NSString pathExtension]", ext);
    }
}

#pragma mark - Permissions, ACLs and file flags from the archive

- (void)testArchiveModesCannotLoosenOrLockOutput {
    NSString *out = [self extractFixtureIntoSubdirectory:@"permissions.tar"];

    NAAssertTrue(([self modeAt:out relative:@""] & 022) == 0,
                 @"a ./ entry should not make the destination group or world writable");
    mode_t script = [self modeAt:out relative:@"world-writable.sh"];
    NAAssertTrue((script & 022) == 0, @"group and other write should be dropped");
    NAAssertTrue((script & 0100) != 0, @"the owner execute bit should be kept");
    NAAssertTrue(([self modeAt:out relative:@"unlistable"] & 0700) == 0700,
                 @"a 0311 directory should stay listable by the owner");
    NAAssertTrue(([self modeAt:out relative:@"readonly"] & 0700) == 0700,
                 @"a 0555 directory should stay writable by the owner");
    NAAssertTrue(([self modeAt:out relative:@"readonly/file.txt"] & 0400) != 0,
                 @"files should stay readable by the owner");
    NAAssertTrue([[NSFileManager defaultManager] removeItemAtPath:out error:nil],
                 @"the output should be removable, as cancel cleanup requires");
}

- (void)testSetuidAndSetgidBitsAreNotRestored {
    NSString *archive = [self.destDir stringByAppendingPathComponent:@"special-bits.tar"];
    struct archive *writer = archive_write_new();
    archive_write_set_format_pax_restricted(writer);
    archive_write_open_filename(writer, archive.fileSystemRepresentation);
    NSDictionary<NSString *, NSNumber *> *files = @{@"setuid.bin": @04755, @"setgid.bin": @02755};
    for (NSString *name in files) {
        struct archive_entry *entry = archive_entry_new();
        archive_entry_set_pathname(entry, name.UTF8String);
        archive_entry_set_filetype(entry, AE_IFREG);
        archive_entry_set_perm(entry, files[name].unsignedShortValue);
        // Owned by the current user, so libarchive would otherwise keep the bits.
        archive_entry_set_uid(entry, getuid());
        archive_entry_set_gid(entry, getgid());
        archive_entry_set_size(entry, 1);
        archive_write_header(writer, entry);
        archive_write_data(writer, "x", 1);
        archive_entry_free(entry);
    }
    archive_write_close(writer);
    archive_write_free(writer);

    NSString *out = [self.destDir stringByAppendingPathComponent:@"out"];
    [[NSFileManager defaultManager] createDirectoryAtPath:out withIntermediateDirectories:YES
                                               attributes:nil error:nil];
    NSError *error = nil;
    BOOL ok = [self.extractor extractArchiveAtPath:archive toDestination:out
                                          progress:nil error:&error];
    NAAssertTrue(ok, @"extraction should succeed: %@", error.localizedDescription);
    NAAssertTrue(([self modeAt:out relative:@"setuid.bin"] & (S_ISUID | S_ISGID)) == 0,
                 @"setuid should not be restored");
    NAAssertTrue(([self modeAt:out relative:@"setgid.bin"] & (S_ISUID | S_ISGID)) == 0,
                 @"setgid should not be restored");
}

- (void)testFileFlagsAndACLsAreNotRestored {
    NSString *out = [self extractFixtureIntoSubdirectory:@"flags-acl.tar"];

    struct stat st;
    lstat([out stringByAppendingPathComponent:@"immutable.txt"].fileSystemRepresentation, &st);
    NAAssertTrue((st.st_flags & (UF_IMMUTABLE | SF_IMMUTABLE)) == 0,
                 @"the uchg flag should not be restored");

    NSString *aclFile = [out stringByAppendingPathComponent:@"acl.txt"];
    // libarchive reports mode 0000 for an entry carrying an NFSv4 ACL.
    NAAssertTrue(([self modeAt:out relative:@"acl.txt"] & 0400) != 0,
                 @"a file with an archived ACL should stay readable by the owner");
    acl_t acl = acl_get_link_np(aclFile.fileSystemRepresentation, ACL_TYPE_EXTENDED);
    NAAssertTrue(acl == NULL, @"no ACL should be set on extracted files");
    if (acl) acl_free(acl);

    NAAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:
                  [out stringByAppendingPathComponent:@"after.txt"]],
                 @"entries after the flagged ones should be extracted");
}

- (NSString *)extractFixtureIntoSubdirectory:(NSString *)fixture {
    NSString *out = [self.destDir stringByAppendingPathComponent:@"out"];
    [[NSFileManager defaultManager] createDirectoryAtPath:out withIntermediateDirectories:YES
                                               attributes:nil error:nil];
    NSError *error = nil;
    BOOL ok = [self.extractor extractArchiveAtPath:[NATestFixtures pathForFixture:fixture]
                                     toDestination:out
                                          progress:nil
                                             error:&error];
    NAAssertTrue(ok, @"%@ should extract: %@", fixture, error.localizedDescription);
    return out;
}

- (mode_t)modeAt:(NSString *)root relative:(NSString *)relativePath {
    struct stat st;
    NSString *path = relativePath.length ? [root stringByAppendingPathComponent:relativePath] : root;
    if (lstat(path.fileSystemRepresentation, &st) != 0) return 0;
    return st.st_mode & 07777;
}

#pragma mark - Read errors and empty archives

- (void)testNonASCIIEntryNamesAreExtracted {
    NSError *error = nil;
    BOOL ok = [self.extractor extractArchiveAtPath:[NATestFixtures pathForFixture:@"non-ascii-names.tar"]
                                     toDestination:self.destDir
                                          progress:nil
                                             error:&error];
    NAAssertTrue(ok, @"extraction should succeed: %@", error.localizedDescription);
    for (NSString *name in @[@"café.txt", @"naïve/résumé.txt", @"after.txt"]) {
        NAAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:
                      [self.destDir stringByAppendingPathComponent:name]],
                     @"%@ should be extracted", name);
    }
}

- (void)testArchiveWithoutEntriesIsNotClaimedOrExtracted {
    NSString *path = [NATestFixtures pathForFixture:@"zero-blocks.zip"];
    NAAssertFalse([NALibarchiveExtractor canHandleFileAtPath:path],
                  @"1024 zero bytes have no entry and should not be claimed");

    NSError *error = nil;
    BOOL ok = [self.extractor extractArchiveAtPath:path toDestination:self.destDir
                                          progress:nil error:&error];
    NAAssertFalse(ok, @"an archive without entries should not report success");
    NAAssertTrue([error.localizedDescription containsString:@"no files"],
                 @"the error should say the archive contains no files, got %@",
                 error.localizedDescription);
}

- (void)testDamagedHeaderReportsFailure {
    NSError *error = nil;
    BOOL ok = [self.extractor extractArchiveAtPath:[NATestFixtures pathForFixture:@"damaged-header.tar"]
                                     toDestination:self.destDir
                                          progress:nil
                                             error:&error];
    NAAssertFalse(ok, @"a damaged header after the first entry should not report success");
    NAAssertNotNil(error, @"the read error should be reported");
}

#pragma mark - Cancellation

- (void)testCancelStopsExtractionAfterCurrentEntry {
    NSString *path = [NATestFixtures pathForFixture:@"multi.zip"];
    NALibarchiveExtractor *extractor = self.extractor;
    NSError *error = nil;
    BOOL ok = [extractor extractArchiveAtPath:path
                                toDestination:self.destDir
                                     progress:^(double fraction, NSString *entry) {
        [extractor cancelExtraction];
    }
                                        error:&error];
    NAAssertFalse(ok, @"cancelled extraction should return NO");
    NAAssertTrue([error.domain isEqualToString:NSCocoaErrorDomain] &&
                 error.code == NSUserCancelledError,
                 @"error should be NSUserCancelledError, got %@", error);
    NAAssertEqual([[NSFileManager defaultManager]
                      contentsOfDirectoryAtPath:self.destDir error:nil].count, 1u,
                  @"only the entry before the cancel should be extracted");
}

#pragma mark - Error handling

- (void)testExtractCorruptArchiveFails {
    NSString *path = [NATestFixtures pathForFixture:@"corrupt.zip"];
    NSError *error = nil;
    BOOL ok = [self.extractor extractArchiveAtPath:path
                                     toDestination:self.destDir
                                          progress:nil
                                             error:&error];
    NAAssertFalse(ok, @"corrupt archive should fail");
    NAAssertNotNil(error, @"error should be set");
}

- (void)testExtractMissingFileFails {
    NSError *error = nil;
    BOOL ok = [self.extractor extractArchiveAtPath:@"/nonexistent/file.zip"
                                     toDestination:self.destDir
                                          progress:nil
                                             error:&error];
    NAAssertFalse(ok, @"missing file should fail");
    NAAssertNotNil(error, @"error should be set");
}

#pragma mark - Path traversal

// Each traversal fixture is extracted into destDir/out; files the archive
// tries to place outside that directory would land in destDir.

- (void)testDotDotEntryDoesNotEscapeDestination {
    NSError *error = nil;
    BOOL ok = [self extractTraversalFixture:@"traversal-dotdot.zip" error:&error];
    NAAssertFalse(ok, @"archive with ../ entry should fail");
    NAAssertNotNil(error, @"error should be set");
    NAAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:
                   [self.destDir stringByAppendingPathComponent:@"canary.txt"]],
                  @"../canary.txt should not be written outside the destination");
}

- (void)testSymlinkEntryDoesNotEscapeDestination {
    NSError *error = nil;
    BOOL ok = [self extractTraversalFixture:@"traversal-symlink.tar" error:&error];
    NAAssertFalse(ok, @"archive writing through a symlink should fail");
    NAAssertNotNil(error, @"error should be set");
    NAAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:
                   [self.destDir stringByAppendingPathComponent:@"canary.txt"]],
                  @"link/canary.txt should not be written through the symlink");
}

- (void)testHardlinkEntryDoesNotEscapeDestination {
    NSString *victim = [self.destDir stringByAppendingPathComponent:@"victim.txt"];
    [@"original" writeToFile:victim atomically:NO
                    encoding:NSUTF8StringEncoding error:nil];

    NSError *error = nil;
    BOOL ok = [self extractTraversalFixture:@"traversal-hardlink.tar" error:&error];
    NAAssertFalse(ok, @"archive with hardlink to ../ should fail");
    NAAssertNotNil(error, @"error should be set");

    NSDictionary *attrs = [[NSFileManager defaultManager]
        attributesOfItemAtPath:victim error:nil];
    NAAssertEqual([attrs[NSFileReferenceCount] integerValue], 1,
                  @"file outside the destination should not gain a hardlink");
}

- (void)testAbsoluteEntryIsPlacedUnderDestination {
    NSError *error = nil;
    BOOL ok = [self extractTraversalFixture:@"traversal-absolute.tar" error:&error];
    NAAssertTrue(ok, @"absolute entry should extract under the destination: %@",
                 error.localizedDescription);
    NAAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:
                  [self.destDir stringByAppendingPathComponent:@"out/absolute.txt"]],
                 @"/absolute.txt should be written to out/absolute.txt");
}

#pragma mark - Supported extensions

- (void)testSupportedExtensions {
    NSArray<NSString *> *exts = [NALibarchiveExtractor supportedExtensions];
    NAAssertTrue(exts.count > 0, @"should have supported extensions");
    NAAssertTrue([exts containsObject:@"zip"], @"should support zip");
    NAAssertTrue([exts containsObject:@"tar"], @"should support tar");
    NAAssertTrue([exts containsObject:@"gz"], @"should support gz");
}

#pragma mark - Helpers

- (void)assertExtractsFixture:(NSString *)name {
    NSString *path = [NATestFixtures pathForFixture:name];
    NAAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:path],
                 @"fixture %@ should exist", name);

    NSError *error = nil;
    BOOL ok = [self.extractor extractArchiveAtPath:path
                                     toDestination:self.destDir
                                          progress:nil
                                             error:&error];
    NAAssertTrue(ok, @"extraction of %@ should succeed: %@", name,
                 error.localizedDescription);

    // Verify extracted content.
    NSString *aPath = [self findFileNamed:@"a.txt" under:self.destDir];
    NAAssertNotNil(aPath, @"a.txt should exist after extracting %@", name);

    NSString *contents = [NSString stringWithContentsOfFile:aPath
                                                   encoding:NSUTF8StringEncoding
                                                      error:nil];
    NAAssertEqualObjects(contents, @"file-a contents\n",
                         @"a.txt contents should match after extracting %@", name);
}

- (BOOL)extractTraversalFixture:(NSString *)name error:(NSError **)error {
    NSString *out = [self.destDir stringByAppendingPathComponent:@"out"];
    [[NSFileManager defaultManager] createDirectoryAtPath:out
                              withIntermediateDirectories:YES
                                               attributes:nil error:nil];
    return [self.extractor extractArchiveAtPath:[NATestFixtures pathForFixture:name]
                                  toDestination:out
                                       progress:nil
                                          error:error];
}

- (NSString *)findFileNamed:(NSString *)name under:(NSString *)dir {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:dir];
    NSString *item;
    while ((item = [enumerator nextObject])) {
        if ([item.lastPathComponent isEqualToString:name]) {
            return [dir stringByAppendingPathComponent:item];
        }
    }
    return nil;
}

@end
