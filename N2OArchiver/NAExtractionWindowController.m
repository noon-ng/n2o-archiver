#import "NAExtractionWindowController.h"
#import "NAPluginManager.h"
#import "NAQuarantine.h"
#include <stdio.h>
#include <sys/mount.h>
#include <sys/stat.h>

@interface NAExtractionWindowController () <NSWindowDelegate>
@property (nonatomic, copy) NSString *archivePath;
@property (nonatomic, strong) NSProgressIndicator *progressBar;
@property (nonatomic, strong) NSTextField *filenameLabel;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSButton *cancelButton;
// Read on the extraction thread, written on the main thread.
@property (atomic, assign) BOOL cancelled;
@property (nonatomic, assign, readwrite, getter=isWorking) BOOL working;
@property (nonatomic, strong, nullable) id<NAExtractorPlugin> extractor;
// Held while working: keeps the app from being suspended by App Nap or quit
// by sudden or automatic termination during an extraction.
@property (nonatomic, strong, nullable) id<NSObject> activity;
// The error shown in the sheet, as composed by presentError:title:.
@property (nonatomic, strong, nullable) NSError *presentedError;
@property (nonatomic, strong, nullable) NSAlert *errorAlert;
@property (nonatomic, strong, nullable) NSView *errorDetailsView;
@property (nonatomic, strong, nullable) NSScrollView *errorDetailsScrollView;
@property (nonatomic, strong, nullable) NSButton *errorDetailsButton;
// Checks free space on the volume holding a path; replaceable in tests.
@property (nonatomic, copy) BOOL (^spaceIsLow)(NSString *path);
// Polls spaceIsLow while working.
@property (nonatomic, strong, nullable) dispatch_source_t spaceMonitor;
// Set when the extraction was stopped for low free space; shown after cleanup.
@property (nonatomic, strong, nullable) NSError *stopError;
@end

@implementation NAExtractionWindowController

- (instancetype)initWithArchivePath:(NSString *)archivePath {
    NSWindow *window = [self createWindow];
    self = [super initWithWindow:window];
    if (self) {
        _archivePath = [archivePath copy];
        _cancelled = NO;
        _spaceIsLow = ^BOOL(NSString *path) {
            struct statfs fs;
            if (statfs(path.fileSystemRepresentation, &fs) != 0) return NO;
            return [NAExtractionWindowController
                isFreeSpaceLowWithAvailable:(uint64_t)fs.f_bavail * fs.f_bsize
                                      total:(uint64_t)fs.f_blocks * fs.f_bsize];
        };
        window.delegate = self;
        [self setupUI];
        self.filenameLabel.stringValue = archivePath.lastPathComponent;
    }
    return self;
}

- (void)beginExtraction {
    [self showWindow:nil];

    id<NAExtractorPlugin> extractor =
        [[NAPluginManager sharedManager] extractorForFileAtPath:self.archivePath];

    if (!extractor) {
        NSError *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                             code:NSFeatureUnsupportedError
                                         userInfo:@{NSLocalizedDescriptionKey:
            @"N2O Archiver does not recognize the format of this file."}];
        [self presentError:error title:[self failureTitle]];
        return;
    }

    NSError *dirError = nil;
    NSString *stagingPath = [self createStagingDirectoryForArchive:self.archivePath
                                                             error:&dirError];
    if (!stagingPath) {
        NSMutableDictionary *userInfo = [@{
            NSLocalizedDescriptionKey:
                @"The folder for the extracted files could not be created next to the archive.",
        } mutableCopy];
        if (dirError) {
            userInfo[NSLocalizedFailureReasonErrorKey] = dirError.localizedDescription;
            userInfo[NSUnderlyingErrorKey] = dirError;
        }
        [self presentError:[NSError errorWithDomain:NSCocoaErrorDomain
                                               code:NSFileWriteUnknownError
                                           userInfo:userInfo]
                     title:[self failureTitle]];
        return;
    }

    self.progressBar.doubleValue = 0.0;
    self.statusLabel.stringValue = @"Extracting…";
    self.extractor = extractor;
    self.working = YES;
    [self startSpaceMonitorForPath:stagingPath];

    __weak typeof(self) weakSelf = self;
    NSString *archivePath = self.archivePath;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        BOOL ok = [extractor extractArchiveAtPath:archivePath
                                    toDestination:stagingPath
                                         progress:^(double fraction, NSString *entry) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) s = weakSelf;
                if (!s || s.cancelled) return;
                s.progressBar.doubleValue = fraction * 100.0;
                s.statusLabel.stringValue = entry ?: @"";
            });
        }
                                            error:&error];

        // Mark everything written, including partial and cancelled output,
        // while it is still in the hidden staging directory. If the app stops
        // during extraction, unmarked files are left only in that directory.
        NSError *quarantineError = nil;
        BOOL quarantined = [NAQuarantine copyQuarantineFromPath:archivePath
                                                   toTreeAtPath:stagingPath
                                                          error:&quarantineError];

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) s = weakSelf;
            if (!s) return;
            s.extractor = nil;

            if (s.cancelled) {
                [s removeCancelledOutputAtPath:stagingPath];
            } else {
                [s finishExtractionInStagingDirectory:stagingPath
                                            succeeded:ok
                                                error:error
                                      quarantineError:quarantined ? nil : quarantineError];
            }
        });
    });
}

// Unwraps a successful extraction, moves the staging directory to its visible
// name and reports the result. A failed extraction's output is removed: it is
// incomplete and may consist of empty files (for example when the extractor
// does not support an entry's compression method).
- (void)finishExtractionInStagingDirectory:(NSString *)stagingPath
                                 succeeded:(BOOL)ok
                                     error:(nullable NSError *)error
                           quarantineError:(nullable NSError *)quarantineError {
    if (!ok) {
        NSError *failure = [self extractionError:error addingQuarantineError:quarantineError];
        self.statusLabel.stringValue = @"Removing partial output…";
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError *removeError = nil;
            BOOL removed = [[NSFileManager defaultManager] removeItemAtPath:stagingPath
                                                                      error:&removeError];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.working = NO;
                [self presentError:removed ? failure
                                           : [self error:failure
                                             notingLeftoverOutputAt:stagingPath
                                                    removeError:removeError]
                             title:[self failureTitle]];
            });
        });
        return;
    }

    if (!quarantineError) {
        [self unwrapSingleItemDirectoryAtPath:stagingPath];
    }

    NSError *moveError = nil;
    NSString *destPath = [self moveStagingDirectory:stagingPath
                            toDestinationForArchive:self.archivePath
                                              error:&moveError];
    self.working = NO;

    if (!destPath) {
        NSMutableDictionary *userInfo = [@{
            NSLocalizedDescriptionKey:
                @"The extracted files could not be moved into place next to the archive.",
            NSLocalizedRecoverySuggestionErrorKey: [NSString stringWithFormat:
                @"They are in the hidden folder “%@”.", stagingPath],
        } mutableCopy];
        if (moveError) {
            userInfo[NSLocalizedFailureReasonErrorKey] = moveError.localizedDescription;
            userInfo[NSUnderlyingErrorKey] = moveError;
        }
        [self presentError:[NSError errorWithDomain:NSCocoaErrorDomain
                                               code:NSFileWriteUnknownError
                                           userInfo:userInfo]
                     title:[self failureTitle]];
    } else if (quarantineError) {
        [self presentError:quarantineError
                     title:[NSString stringWithFormat:
            @"“%@” was extracted, but some files are not marked as downloaded.",
            self.archivePath.lastPathComponent]];
    } else {
        [self extractionFinishedAtPath:destPath];
    }
}

// The extraction error, with a quarantine failure for the partial output
// appended to its recovery suggestion so both appear in the sheet.
- (NSError *)extractionError:(nullable NSError *)error
       addingQuarantineError:(nullable NSError *)quarantineError {
    if (!error) {
        error = [NSError errorWithDomain:NSCocoaErrorDomain
                                    code:NSFileReadUnknownError
                                userInfo:@{NSLocalizedDescriptionKey: @"Extraction failed."}];
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
    notingLeftoverOutputAt:(NSString *)path
               removeError:(nullable NSError *)removeError {
    NSMutableDictionary *userInfo = [error.userInfo mutableCopy];
    userInfo[NSLocalizedDescriptionKey] = error.localizedDescription;
    NSString *note = [NSString stringWithFormat:
        @"The partially extracted files could not be removed and are in the hidden folder “%@”.%@",
        path, removeError ? [@" " stringByAppendingString:removeError.localizedDescription] : @""];
    NSString *suggestion = error.localizedRecoverySuggestion;
    userInfo[NSLocalizedRecoverySuggestionErrorKey] =
        suggestion.length > 0 ? [NSString stringWithFormat:@"%@\n\n%@", suggestion, note] : note;
    return [NSError errorWithDomain:error.domain code:error.code userInfo:userInfo];
}

// Removes the output of a cancelled extraction off the main thread, then
// closes the window. The window stays open until then so that the app, which
// quits when its last extraction window closes, does not exit before cleanup.
- (void)removeCancelledOutputAtPath:(NSString *)stagingPath {
    self.statusLabel.stringValue = @"Removing partial output…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // The staging directory was created for this extraction, so it held
        // nothing before; its contents were already marked as quarantined.
        [[NSFileManager defaultManager] removeItemAtPath:stagingPath error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.working = NO;
            if (self.stopError) {
                [self presentError:self.stopError title:[self failureTitle]];
            } else {
                [self close];
            }
        });
    });
}

+ (BOOL)isFreeSpaceLowWithAvailable:(uint64_t)available total:(uint64_t)total {
    const uint64_t oneGigabyte = 1000ull * 1000 * 1000;
    return available < MIN(oneGigabyte, total / 20);
}

// Stops the extraction when free space on the destination volume runs low, so
// an archive that expands far beyond its size (for example a zip bomb) cannot
// fill the volume. The output is removed through the cancel path.
- (void)startSpaceMonitorForPath:(NSString *)path {
    dispatch_source_t timer =
        dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(0.25 * NSEC_PER_SEC), (uint64_t)(0.05 * NSEC_PER_SEC));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        __strong typeof(weakSelf) s = weakSelf;
        if (!s || s.cancelled || !s.spaceIsLow(path)) return;

        s.stopError = [NSError errorWithDomain:NSCocoaErrorDomain
                                          code:NSFileWriteOutOfSpaceError
                                      userInfo:@{
            NSLocalizedDescriptionKey: @"Extraction was stopped.",
            NSLocalizedRecoverySuggestionErrorKey:
                @"The disk is almost full: free space dropped below 1 GB, or below 5% of "
                @"the volume if that is smaller. The partially extracted files were removed.",
        }];
        [s cancelExtraction:nil];
    });
    self.spaceMonitor = timer;
    dispatch_resume(timer);
}

- (void)setWorking:(BOOL)working {
    _working = working;
    if (!working && self.spaceMonitor) {
        dispatch_source_cancel(self.spaceMonitor);
        self.spaceMonitor = nil;
    }
    NSProcessInfo *processInfo = [NSProcessInfo processInfo];
    if (working && !self.activity) {
        self.activity = [processInfo beginActivityWithOptions:NSActivityUserInitiated
                                                       reason:@"Extracting an archive"];
    } else if (!working && self.activity) {
        [processInfo endActivity:self.activity];
        self.activity = nil;
    }
}

#pragma mark - Destination path logic

- (NSString *)destinationPathForArchive:(NSString *)archivePath {
    NSString *parent = archivePath.stringByDeletingLastPathComponent;
    NSString *baseName = archivePath.lastPathComponent;

    // Strip known compound extensions like .tar.gz
    NSArray<NSString *> *compoundExts = @[
        @".tar.gz", @".tar.bz2", @".tar.xz", @".tar.lz", @".tar.zst"
    ];
    for (NSString *ext in compoundExts) {
        if ([baseName.lowercaseString hasSuffix:ext]) {
            baseName = [baseName substringToIndex:baseName.length - ext.length];
            return [parent stringByAppendingPathComponent:baseName];
        }
    }

    return [parent stringByAppendingPathComponent:
            baseName.stringByDeletingPathExtension];
}

// Creates a hidden directory next to the archive to extract into. The output
// gets its visible name only after it has been marked with the archive's
// quarantine value.
- (nullable NSString *)createStagingDirectoryForArchive:(NSString *)archivePath
                                                 error:(NSError **)error {
    NSString *path = [archivePath.stringByDeletingLastPathComponent
        stringByAppendingPathComponent:
            [@".n2o-extract-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    if (mkdir(path.fileSystemRepresentation, 0755) == 0) return path;

    if (error) {
        *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                     code:errno
                                 userInfo:@{NSFilePathErrorKey: path}];
    }
    return nil;
}

// Renames the staging directory to the archive's base name, or "<name> 2",
// "<name> 3", ... if that name is taken by any file or directory. RENAME_EXCL
// makes the rename fail with EEXIST instead of replacing an existing item.
- (nullable NSString *)moveStagingDirectory:(NSString *)stagingPath
                    toDestinationForArchive:(NSString *)archivePath
                                      error:(NSError **)error {
    NSString *base = [self destinationPathForArchive:archivePath];

    for (NSUInteger n = 1; ; n++) {
        NSString *candidate = (n == 1)
            ? base
            : [NSString stringWithFormat:@"%@ %lu", base, (unsigned long)n];

        if (renamex_np(stagingPath.fileSystemRepresentation,
                       candidate.fileSystemRepresentation, RENAME_EXCL) == 0) {
            return candidate;
        }
        if (errno != EEXIST) {
            if (error) {
                *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                             code:errno
                                         userInfo:@{NSFilePathErrorKey: candidate}];
            }
            return nil;
        }
    }
}

#pragma mark - Completion

- (void)extractionFinishedAtPath:(NSString *)destPath {
    self.progressBar.doubleValue = 100.0;
    self.statusLabel.stringValue = @"Done.";

    // Reveal in Finder.
    [[NSWorkspace sharedWorkspace] selectFile:nil
                     inFileViewerRootedAtPath:destPath];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self close];
    });
}

- (void)unwrapSingleItemDirectoryAtPath:(NSString *)destPath {
    NSFileManager *fm = [NSFileManager defaultManager];

    // Only unwrap when the destination holds exactly one item besides
    // .DS_Store, so moved children can only collide with .DS_Store.
    NSMutableArray<NSString *> *items = [NSMutableArray array];
    for (NSString *item in [fm contentsOfDirectoryAtPath:destPath error:nil]) {
        if (![item isEqualToString:@".DS_Store"]) [items addObject:item];
    }
    if (items.count != 1) return;

    // attributesOfItemAtPath: does not follow symlinks, so a symlink to a
    // directory elsewhere on disk is left alone.
    NSString *singleItem = [destPath stringByAppendingPathComponent:items[0]];
    NSDictionary *attrs = [fm attributesOfItemAtPath:singleItem error:nil];
    if (![attrs.fileType isEqualToString:NSFileTypeDirectory]) return;

    // Rename the directory first so a child with the same name (x/x) does not
    // collide with it when moved up.
    NSString *staging = [destPath stringByAppendingPathComponent:
        [@".n2o-unwrap-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    if (![fm moveItemAtPath:singleItem toPath:staging error:nil]) return;

    NSArray<NSString *> *children = [fm contentsOfDirectoryAtPath:staging error:nil];
    NSMutableArray<NSString *> *moved = [NSMutableArray array];
    BOOL failed = (children == nil);
    for (NSString *child in children) {
        if (![fm moveItemAtPath:[staging stringByAppendingPathComponent:child]
                         toPath:[destPath stringByAppendingPathComponent:child]
                          error:nil]) {
            failed = YES;
            break;
        }
        [moved addObject:child];
    }

    if (failed) {
        // Restore the original layout. Nothing is deleted on this path.
        for (NSString *child in moved) {
            [fm moveItemAtPath:[destPath stringByAppendingPathComponent:child]
                        toPath:[staging stringByAppendingPathComponent:child]
                         error:nil];
        }
        if (![fm moveItemAtPath:staging toPath:singleItem error:nil]) {
            NSLog(@"N2OArchiver: could not restore %@ from %@", singleItem, staging);
        }
        return;
    }

    // rmdir only removes an empty directory.
    if (rmdir(staging.fileSystemRepresentation) != 0) {
        NSLog(@"N2OArchiver: could not remove %@: %s", staging, strerror(errno));
    }
}

#pragma mark - Error display

- (NSString *)failureTitle {
    return [NSString stringWithFormat:@"“%@” could not be extracted.",
            self.archivePath.lastPathComponent];
}

// Longer recovery suggestions go into the collapsible details area.
static const NSUInteger NAMaxSummarySuggestionLength = 300;

// Shows the error as a sheet on the extraction window and closes the window
// when the sheet is dismissed. The sheet shows the title and a short summary
// with the Close button; longer text, such as 7zz output with one line per
// file, goes into a collapsed "Details" area that scrolls within a fixed
// height, so the sheet stays within the screen.
- (void)presentError:(NSError *)error title:(NSString *)title {
    self.statusLabel.stringValue = title;
    self.progressBar.hidden = YES;
    self.cancelButton.title = @"Close";
    self.cancelButton.action = @selector(close);

    NSString *description = error.localizedDescription ?: @"";
    NSString *reason = error.localizedFailureReason ?: @"";
    NSString *suggestion = error.localizedRecoverySuggestion ?: @"";

    NSMutableArray<NSString *> *summary = [NSMutableArray array];
    NSMutableArray<NSString *> *details = [NSMutableArray array];
    if (description.length > 0) [summary addObject:description];
    if (suggestion.length > 0 && ![summary containsObject:suggestion]) {
        [(suggestion.length <= NAMaxSummarySuggestionLength ? summary : details) addObject:suggestion];
    }
    if (reason.length > 0 && ![summary containsObject:reason] && ![details containsObject:reason]) {
        [details addObject:reason];
    }

    NSMutableArray<NSString *> *all = [summary mutableCopy];
    [all addObjectsFromArray:details];
    NSMutableDictionary *userInfo = [@{
        NSLocalizedDescriptionKey: title,
        NSUnderlyingErrorKey: error,
    } mutableCopy];
    if (all.count > 0) {
        userInfo[NSLocalizedRecoverySuggestionErrorKey] = [all componentsJoinedByString:@"\n\n"];
    }
    self.presentedError = [NSError errorWithDomain:error.domain code:error.code userInfo:userInfo];

    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = title;
    alert.informativeText = [summary componentsJoinedByString:@"\n\n"];
    [alert addButtonWithTitle:@"Close"];
    if (details.count > 0) {
        alert.accessoryView = [self errorDetailsViewWithText:[details componentsJoinedByString:@"\n\n"]];
    }
    [alert layout];
    self.errorAlert = alert;

    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        self.errorAlert = nil;
        [self close];
    }];
}

static const CGFloat NAErrorDetailsWidth = 400;
static const CGFloat NAErrorDetailsHeight = 180;

- (NSView *)errorDetailsViewWithText:(NSString *)text {
    NSButton *button = [NSButton buttonWithTitle:@"Show Details"
                                          target:self
                                          action:@selector(toggleErrorDetails:)];
    [button sizeToFit];

    NSScrollView *scrollView = [[NSScrollView alloc]
        initWithFrame:NSMakeRect(0, 0, NAErrorDetailsWidth, NAErrorDetailsHeight)];
    scrollView.hasVerticalScroller = YES;
    scrollView.borderType = NSBezelBorder;
    scrollView.hidden = YES;

    NSTextView *textView = [[NSTextView alloc] initWithFrame:scrollView.contentView.bounds];
    textView.string = text;
    textView.editable = NO;
    textView.selectable = YES;
    textView.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    textView.autoresizingMask = NSViewWidthSizable;
    textView.textContainer.widthTracksTextView = YES;
    scrollView.documentView = textView;

    NSView *container = [[NSView alloc] init];
    [container addSubview:button];
    [container addSubview:scrollView];
    self.errorDetailsView = container;
    self.errorDetailsScrollView = scrollView;
    self.errorDetailsButton = button;
    [self layoutErrorDetails];
    return container;
}

- (void)toggleErrorDetails:(id)sender {
    self.errorDetailsScrollView.hidden = !self.errorDetailsScrollView.hidden;
    self.errorDetailsButton.title = self.errorDetailsScrollView.hidden ? @"Show Details" : @"Hide Details";
    [self.errorDetailsButton sizeToFit];
    [self layoutErrorDetails];
    [self.errorAlert layout];
}

// Places the button above the scroll view when it is shown; the container
// height follows, and NSAlert's layout resizes the sheet.
- (void)layoutErrorDetails {
    CGFloat buttonHeight = NSHeight(self.errorDetailsButton.frame);
    CGFloat detailsHeight = self.errorDetailsScrollView.hidden ? 0 : NAErrorDetailsHeight + 8;
    self.errorDetailsView.frame = NSMakeRect(0, 0, NAErrorDetailsWidth, buttonHeight + detailsHeight);
    [self.errorDetailsButton setFrameOrigin:NSMakePoint(0, detailsHeight)];
    self.errorDetailsScrollView.frame = NSMakeRect(0, 0, NAErrorDetailsWidth, NAErrorDetailsHeight);
}

#pragma mark - Actions

- (void)cancelExtraction:(id)sender {
    if (!self.working) {
        [self close];
        return;
    }
    if (self.cancelled) return;

    self.cancelled = YES;
    if ([self.extractor respondsToSelector:@selector(cancelExtraction)]) {
        [self.extractor cancelExtraction];
    }
    self.statusLabel.stringValue = @"Cancelling…";
    self.cancelButton.enabled = NO;
}

#pragma mark - NSWindowDelegate

// The close button cancels a running extraction; the window closes once the
// cancelled output has been removed.
- (BOOL)windowShouldClose:(NSWindow *)sender {
    if (!self.working) return YES;
    [self cancelExtraction:sender];
    return NO;
}

#pragma mark - Window and UI setup

- (NSWindow *)createWindow {
    NSRect frame = NSMakeRect(0, 0, 420, 120);
    NSWindow *window =
        [[NSWindow alloc] initWithContentRect:frame
                                    styleMask:(NSWindowStyleMaskTitled |
                                               NSWindowStyleMaskClosable)
                                      backing:NSBackingStoreBuffered
                                        defer:NO];
    window.title = @"N2O Archiver";
    window.releasedWhenClosed = NO;
    [window center];
    return window;
}

- (void)setupUI {
    NSView *content = self.window.contentView;

    // Filename label
    self.filenameLabel = [NSTextField labelWithString:@""];
    self.filenameLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    self.filenameLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    self.filenameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:self.filenameLabel];

    // Progress bar
    self.progressBar = [[NSProgressIndicator alloc] init];
    self.progressBar.style = NSProgressIndicatorStyleBar;
    self.progressBar.minValue = 0.0;
    self.progressBar.maxValue = 100.0;
    self.progressBar.doubleValue = 0.0;
    self.progressBar.indeterminate = NO;
    self.progressBar.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:self.progressBar];

    // Status label
    self.statusLabel = [NSTextField labelWithString:@"Preparing…"];
    self.statusLabel.font = [NSFont systemFontOfSize:11];
    self.statusLabel.textColor = NSColor.secondaryLabelColor;
    self.statusLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:self.statusLabel];

    // Cancel button
    self.cancelButton = [NSButton buttonWithTitle:@"Cancel"
                                           target:self
                                           action:@selector(cancelExtraction:)];
    self.cancelButton.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:self.cancelButton];

    NSDictionary *views = @{
        @"name": self.filenameLabel,
        @"bar": self.progressBar,
        @"status": self.statusLabel,
        @"cancel": self.cancelButton
    };

    [content addConstraints:
        [NSLayoutConstraint constraintsWithVisualFormat:@"H:|-20-[name]-20-|"
                                               options:0 metrics:nil views:views]];
    [content addConstraints:
        [NSLayoutConstraint constraintsWithVisualFormat:@"H:|-20-[bar]-20-|"
                                               options:0 metrics:nil views:views]];
    [content addConstraints:
        [NSLayoutConstraint constraintsWithVisualFormat:@"H:|-20-[status]-(>=8)-[cancel]-20-|"
                                               options:NSLayoutFormatAlignAllCenterY
                                               metrics:nil views:views]];
    [content addConstraints:
        [NSLayoutConstraint constraintsWithVisualFormat:@"V:|-16-[name]-10-[bar]-8-[status]-12-|"
                                               options:0 metrics:nil views:views]];
}

@end
