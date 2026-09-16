#import "NAExtractionJob.h"
#import "NAQuarantine.h"
#import "NALog.h"
#include <stdio.h>
#include <sys/mount.h>
#include <sys/stat.h>

@interface NAExtractionJob ()
@property (nonatomic, readwrite) NAExtractionJobState state;
@property (nonatomic, readwrite, copy, nullable) NSURL *destinationURL;
@property (nonatomic, readwrite, strong, nullable) NSError *error;
// Passed to the extractor, which updates it on its own threads; cancelled by
// cancel. Read on the extraction queue and by the monitor.
@property (nonatomic, strong) NSProgress *progress;
@property (nonatomic, copy, nullable) NSURL *stagingURL;
// Held while active: keeps the app from being suspended by App Nap or quit by
// sudden or automatic termination during an extraction.
@property (nonatomic, strong, nullable) id<NSObject> activity;
// Reports progress and checks free space while active.
@property (nonatomic, strong, nullable) dispatch_source_t monitor;
@property (nonatomic, assign) double reportedFraction;
@property (nonatomic, copy, nullable) NSURL *reportedFileURL;
// Set when the job stopped itself for low free space; reported as its error.
@property (nonatomic, strong, nullable) NSError *stopError;
@end

@implementation NAExtractionJob {
    NAPluginManager *_pluginManager;
}

- (instancetype)initWithArchiveURL:(NSURL *)archiveURL
                     pluginManager:(NAPluginManager *)pluginManager {
    self = [super init];
    if (self) {
        _archiveURL = [archiveURL copy];
        _pluginManager = pluginManager;
        _state = NAExtractionJobStatePending;
        _progress = [NSProgress discreteProgressWithTotalUnitCount:0];
        _reportedFraction = -1;
        _spaceIsLow = ^BOOL(NSURL *url) {
            struct statfs fs;
            if (statfs(url.fileSystemRepresentation, &fs) != 0) return NO;
            return [NAExtractionJob isFreeSpaceLowWithAvailable:(uint64_t)fs.f_bavail * fs.f_bsize
                                                          total:(uint64_t)fs.f_blocks * fs.f_bsize];
        };
    }
    return self;
}

- (BOOL)isActive {
    return self.state == NAExtractionJobStateExtracting ||
           self.state == NAExtractionJobStateCancelling;
}

+ (BOOL)isFreeSpaceLowWithAvailable:(uint64_t)available total:(uint64_t)total {
    const uint64_t oneGigabyte = 1000ull * 1000 * 1000;
    return available < MIN(oneGigabyte, total / 20);
}

#pragma mark - Running

- (void)start {
    if (self.state != NAExtractionJobStatePending) return;

    id<NAExtractorPlugin> extractor = [_pluginManager extractorForFileAtURL:self.archiveURL];
    if (!extractor) {
        [self finishWithState:NAExtractionJobStateFailed
                        error:[NSError errorWithDomain:NSCocoaErrorDomain
                                                  code:NSFeatureUnsupportedError
                                              userInfo:@{NSLocalizedDescriptionKey:
            NSLocalizedString(@"N2O Archiver does not recognize the format of this file.",
                              @"Error when no extractor handles the file")}]];
        return;
    }

    NSError *dirError = nil;
    NSURL *stagingURL = [self createStagingDirectoryForArchive:self.archiveURL error:&dirError];
    if (!stagingURL) {
        NSMutableDictionary *userInfo = [@{
            NSLocalizedDescriptionKey:
                NSLocalizedString(@"The folder for the extracted files could not be created next to the archive.",
                                  @"Error when the staging directory cannot be created"),
        } mutableCopy];
        if (dirError) {
            userInfo[NSLocalizedFailureReasonErrorKey] = dirError.localizedDescription;
            userInfo[NSUnderlyingErrorKey] = dirError;
        }
        [self finishWithState:NAExtractionJobStateFailed
                        error:[NSError errorWithDomain:NSCocoaErrorDomain
                                                  code:NSFileWriteUnknownError
                                              userInfo:userInfo]];
        return;
    }

    self.stagingURL = stagingURL;
    self.state = NAExtractionJobStateExtracting;
    self.activity = [[NSProcessInfo processInfo] beginActivityWithOptions:NSActivityUserInitiated
                                                                   reason:@"Extracting an archive"];
    [self startMonitor];

    // The block keeps the job alive until it has finished.
    NSURL *archiveURL = self.archiveURL;
    NSProgress *progress = self.progress;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        BOOL ok = [extractor extractArchiveAtURL:archiveURL
                                toDestinationURL:stagingURL
                                        progress:progress
                                           error:&error];

        // Mark everything written, including partial and cancelled output,
        // while it is still in the hidden staging directory. If the app stops
        // during extraction, unmarked files are left only in that directory.
        NSError *quarantineError = nil;
        BOOL quarantined = [NAQuarantine copyQuarantineFromURL:archiveURL
                                                   toTreeAtURL:stagingURL
                                                         error:&quarantineError];
        if (quarantined) quarantineError = nil;

        if (progress.isCancelled) {
            // The staging directory was created for this job, so it held
            // nothing before; its contents were already marked.
            [[NSFileManager defaultManager] removeItemAtURL:stagingURL error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self finishWithState:NAExtractionJobStateCancelled error:self.stopError];
            });
            return;
        }

        [self finishInStagingDirectory:stagingURL
                             succeeded:ok
                                 error:error
                       quarantineError:quarantineError];
    });
}

- (void)cancel {
    switch (self.state) {
        case NAExtractionJobStatePending:
            [self finishWithState:NAExtractionJobStateCancelled error:nil];
            break;
        case NAExtractionJobStateExtracting:
            self.state = NAExtractionJobStateCancelling;
            [self.progress cancel];
            break;
        default:
            break;
    }
}

// Runs on the extraction queue. Unwraps a successful, fully marked extraction,
// moves the staging directory to its visible name, and reports the result on
// the main queue. A failed extraction's output is removed: it is incomplete
// and may consist of empty files (for example when the extractor does not
// support an entry's compression method).
- (void)finishInStagingDirectory:(NSURL *)stagingURL
                       succeeded:(BOOL)ok
                           error:(nullable NSError *)error
                 quarantineError:(nullable NSError *)quarantineError {
    if (!ok) {
        NSError *failure = [self extractionError:error addingQuarantineError:quarantineError];
        NSError *removeError = nil;
        if (![[NSFileManager defaultManager] removeItemAtURL:stagingURL error:&removeError]) {
            failure = [self error:failure notingLeftoverOutputAt:stagingURL removeError:removeError];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self finishWithState:NAExtractionJobStateFailed error:failure];
        });
        return;
    }

    if (!quarantineError) {
        [self unwrapSingleItemDirectoryAtURL:stagingURL];
    }

    NSError *moveError = nil;
    NSURL *destinationURL = [self moveStagingDirectory:stagingURL
                               toDestinationForArchive:self.archiveURL
                                                 error:&moveError];

    dispatch_async(dispatch_get_main_queue(), ^{
        if (!destinationURL) {
            NSMutableDictionary *userInfo = [@{
                NSLocalizedDescriptionKey:
                    NSLocalizedString(@"The extracted files could not be moved into place next to the archive.",
                                      @"Error when the output cannot be renamed"),
                NSLocalizedRecoverySuggestionErrorKey: [NSString stringWithFormat:
                    NSLocalizedString(@"They are in the hidden folder “%@”.",
                                      @"Where the output was left; %@ is a folder path"),
                    stagingURL.path],
            } mutableCopy];
            if (moveError) {
                userInfo[NSLocalizedFailureReasonErrorKey] = moveError.localizedDescription;
                userInfo[NSUnderlyingErrorKey] = moveError;
            }
            [self finishWithState:NAExtractionJobStateFailed
                            error:[NSError errorWithDomain:NSCocoaErrorDomain
                                                      code:NSFileWriteUnknownError
                                                  userInfo:userInfo]];
            return;
        }

        self.destinationURL = destinationURL;
        [self finishWithState:NAExtractionJobStateSucceeded error:quarantineError];
    });
}

- (void)finishWithState:(NAExtractionJobState)state error:(nullable NSError *)error {
    if (self.monitor) {
        dispatch_source_cancel(self.monitor);
        self.monitor = nil;
    }
    if (self.activity) {
        [[NSProcessInfo processInfo] endActivity:self.activity];
        self.activity = nil;
    }
    self.error = error;
    self.state = state;

    void (^completion)(NAExtractionJob *) = self.completionHandler;
    self.completionHandler = nil;
    if (completion) completion(self);
}

// The extraction error, with a quarantine failure for the partial output
// appended to its recovery suggestion so both can be shown together.
- (NSError *)extractionError:(nullable NSError *)error
       addingQuarantineError:(nullable NSError *)quarantineError {
    if (!error) {
        error = [NSError errorWithDomain:NSCocoaErrorDomain
                                    code:NSFileReadUnknownError
                                userInfo:@{NSLocalizedDescriptionKey:
            NSLocalizedString(@"Extraction failed.",
                              @"Error when an extractor fails without a message")}];
    }
    if (!quarantineError) return error;

    NSMutableArray<NSString *> *suggestion = [NSMutableArray array];
    for (NSString *text in @[error.localizedRecoverySuggestion ?: @"",
                             quarantineError.localizedDescription ?: @"",
                             quarantineError.localizedRecoverySuggestion ?: @""]) {
        if (text.length > 0) [suggestion addObject:text];
    }
    NSMutableDictionary *userInfo = [error.userInfo mutableCopy];
    userInfo[NSLocalizedDescriptionKey] = error.localizedDescription;
    userInfo[NSLocalizedRecoverySuggestionErrorKey] = [suggestion componentsJoinedByString:@"\n\n"];
    return [NSError errorWithDomain:error.domain code:error.code userInfo:userInfo];
}

// The failure with a note that the partial output could not be removed.
- (NSError *)error:(NSError *)error
    notingLeftoverOutputAt:(NSURL *)url
               removeError:(nullable NSError *)removeError {
    NSMutableDictionary *userInfo = [error.userInfo mutableCopy];
    userInfo[NSLocalizedDescriptionKey] = error.localizedDescription;
    NSString *note = [NSString stringWithFormat:
        NSLocalizedString(@"The partially extracted files could not be removed and are in the hidden folder “%@”.%@",
                          @"Leftover output note; %@ is a folder path, then the reason or nothing"),
        url.path, removeError ? [@" " stringByAppendingString:removeError.localizedDescription] : @""];
    NSString *suggestion = error.localizedRecoverySuggestion;
    userInfo[NSLocalizedRecoverySuggestionErrorKey] =
        suggestion.length > 0 ? [NSString stringWithFormat:@"%@\n\n%@", suggestion, note] : note;
    return [NSError errorWithDomain:error.domain code:error.code userInfo:userInfo];
}

#pragma mark - Monitor

// Every 0.1 s while extracting, passes changed progress to progressHandler,
// then stops the extraction if free space on the destination volume is low,
// so an archive that expands far beyond its size (for example a zip bomb)
// cannot fill the volume. The output is removed through the cancel path.
- (void)startMonitor {
    dispatch_source_t timer =
        dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(0.1 * NSEC_PER_SEC), (uint64_t)(0.02 * NSEC_PER_SEC));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        __strong typeof(weakSelf) s = weakSelf;
        if (!s || s.state != NAExtractionJobStateExtracting) return;
        [s reportProgress];
        if (!s.spaceIsLow(s.stagingURL)) return;

        s.stopError = [NSError errorWithDomain:NSCocoaErrorDomain
                                          code:NSFileWriteOutOfSpaceError
                                      userInfo:@{
            NSLocalizedDescriptionKey: NSLocalizedString(@"Extraction was stopped.",
                                                         @"Error when free space runs low"),
            NSLocalizedRecoverySuggestionErrorKey: NSLocalizedString(
                @"The disk is almost full: free space dropped below 1 GB, or below 5% of "
                @"the volume if that is smaller. The partially extracted files were removed.",
                @"Why the extraction was stopped"),
        }];
        [s cancel];
    });
    self.monitor = timer;
    dispatch_resume(timer);
}

- (void)reportProgress {
    double fraction = self.progress.fractionCompleted;
    NSURL *fileURL = self.progress.fileURL;
    if (fraction == self.reportedFraction && (fileURL == self.reportedFileURL ||
                                              [fileURL isEqual:self.reportedFileURL])) {
        return;
    }
    self.reportedFraction = fraction;
    self.reportedFileURL = fileURL;
    if (self.progressHandler) self.progressHandler(fraction, fileURL.lastPathComponent ?: @"");
}

#pragma mark - Destination

- (NSURL *)destinationURLForArchive:(NSURL *)archiveURL {
    NSURL *parent = archiveURL.URLByDeletingLastPathComponent;
    NSString *baseName = archiveURL.lastPathComponent;

    // Strip known compound extensions like .tar.gz
    NSArray<NSString *> *compoundExts = @[
        @".tar.gz", @".tar.bz2", @".tar.xz", @".tar.lz", @".tar.zst"
    ];
    for (NSString *ext in compoundExts) {
        if ([baseName.lowercaseString hasSuffix:ext]) {
            baseName = [baseName substringToIndex:baseName.length - ext.length];
            return [parent URLByAppendingPathComponent:baseName isDirectory:YES];
        }
    }

    return [parent URLByAppendingPathComponent:archiveURL.URLByDeletingPathExtension.lastPathComponent
                                   isDirectory:YES];
}

// Creates a hidden directory next to the archive to extract into. The output
// gets its visible name only after it has been marked with the archive's
// quarantine value.
- (nullable NSURL *)createStagingDirectoryForArchive:(NSURL *)archiveURL
                                               error:(NSError **)error {
    NSURL *url = [archiveURL.URLByDeletingLastPathComponent
        URLByAppendingPathComponent:[@".n2o-extract-" stringByAppendingString:NSUUID.UUID.UUIDString]
                        isDirectory:YES];
    if (mkdir(url.fileSystemRepresentation, 0755) == 0) return url;

    if (error) {
        *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                     code:errno
                                 userInfo:@{NSURLErrorKey: url}];
    }
    return nil;
}

// Renames the staging directory to the archive's base name, or "<name> 2",
// "<name> 3", ... if that name is taken by any file or directory. RENAME_EXCL
// makes the rename fail with EEXIST instead of replacing an existing item.
- (nullable NSURL *)moveStagingDirectory:(NSURL *)stagingURL
                 toDestinationForArchive:(NSURL *)archiveURL
                                   error:(NSError **)error {
    NSURL *base = [self destinationURLForArchive:archiveURL];

    for (NSUInteger n = 1; ; n++) {
        NSURL *candidate = (n == 1)
            ? base
            : [base.URLByDeletingLastPathComponent
                  URLByAppendingPathComponent:[NSString stringWithFormat:@"%@ %lu",
                                                  base.lastPathComponent, (unsigned long)n]
                                  isDirectory:YES];

        if (renamex_np(stagingURL.fileSystemRepresentation,
                       candidate.fileSystemRepresentation, RENAME_EXCL) == 0) {
            return candidate;
        }
        if (errno != EEXIST) {
            if (error) {
                *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                             code:errno
                                         userInfo:@{NSURLErrorKey: candidate}];
            }
            return nil;
        }
    }
}

- (void)unwrapSingleItemDirectoryAtURL:(NSURL *)destinationURL {
    NSFileManager *fm = [NSFileManager defaultManager];

    // Only unwrap when the destination holds exactly one item besides
    // .DS_Store, so moved children can only collide with .DS_Store.
    NSMutableArray<NSURL *> *items = [NSMutableArray array];
    for (NSURL *item in [fm contentsOfDirectoryAtURL:destinationURL
                          includingPropertiesForKeys:nil
                                             options:0
                                               error:nil]) {
        if (![item.lastPathComponent isEqualToString:@".DS_Store"]) [items addObject:item];
    }
    if (items.count != 1) return;

    // attributesOfItemAtPath: does not follow symlinks, so a symlink to a
    // directory elsewhere on disk is left alone.
    NSURL *singleItem = items[0];
    NSDictionary *attrs = [fm attributesOfItemAtPath:singleItem.path error:nil];
    if (![attrs.fileType isEqualToString:NSFileTypeDirectory]) return;

    // Rename the directory first so a child with the same name (x/x) does not
    // collide with it when moved up.
    NSURL *staging = [destinationURL
        URLByAppendingPathComponent:[@".n2o-unwrap-" stringByAppendingString:NSUUID.UUID.UUIDString]
                        isDirectory:YES];
    if (![fm moveItemAtURL:singleItem toURL:staging error:nil]) return;

    NSArray<NSURL *> *children = [fm contentsOfDirectoryAtURL:staging
                                  includingPropertiesForKeys:nil
                                                     options:0
                                                       error:nil];
    NSMutableArray<NSString *> *moved = [NSMutableArray array];
    BOOL failed = (children == nil);
    for (NSURL *child in children) {
        NSString *name = child.lastPathComponent;
        if (![fm moveItemAtURL:child
                         toURL:[destinationURL URLByAppendingPathComponent:name]
                         error:nil]) {
            failed = YES;
            break;
        }
        [moved addObject:name];
    }

    if (failed) {
        // Restore the original layout. Nothing is deleted on this path.
        for (NSString *name in moved) {
            [fm moveItemAtURL:[destinationURL URLByAppendingPathComponent:name]
                        toURL:[staging URLByAppendingPathComponent:name]
                        error:nil];
        }
        if (![fm moveItemAtURL:staging toURL:singleItem error:nil]) {
            os_log_error(NALog(), "could not restore %{private}@ from %{private}@",
                         singleItem.path, staging.path);
        }
        return;
    }

    // rmdir only removes an empty directory.
    if (rmdir(staging.fileSystemRepresentation) != 0) {
        os_log_error(NALog(), "could not remove %{private}@: %{public}s",
                     staging.path, strerror(errno));
    }
}

@end
