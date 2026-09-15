#import "NAExtractionWindowController.h"
#import "NAPluginManager.h"
#import "NAQuarantine.h"
#include <stdio.h>
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
@end

@implementation NAExtractionWindowController

- (instancetype)initWithArchivePath:(NSString *)archivePath {
    NSWindow *window = [self createWindow];
    self = [super initWithWindow:window];
    if (self) {
        _archivePath = [archivePath copy];
        _cancelled = NO;
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
// name and reports the result. A failed extraction that wrote nothing leaves
// no folder behind.
- (void)finishExtractionInStagingDirectory:(NSString *)stagingPath
                                 succeeded:(BOOL)ok
                                     error:(nullable NSError *)error
                           quarantineError:(nullable NSError *)quarantineError {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *failure = ok ? nil : [self extractionError:error
                                    addingQuarantineError:quarantineError];

    if (!ok && [fm contentsOfDirectoryAtPath:stagingPath error:nil].count == 0) {
        rmdir(stagingPath.fileSystemRepresentation);
        self.working = NO;
        [self presentError:failure title:[self failureTitle]];
        return;
    }

    if (ok && !quarantineError) {
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
    } else if (!ok) {
        [self presentError:failure title:[self failureTitle]];
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
            [self close];
        });
    });
}

- (void)setWorking:(BOOL)working {
    _working = working;
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

// Shows the error as a sheet on the extraction window and closes the window
// when the sheet is dismissed. The sheet title names the archive; its text
// combines the error's description, failure reason and recovery suggestion,
// so long messages such as 7zz output are shown in full and can be selected.
- (void)presentError:(NSError *)error title:(NSString *)title {
    self.statusLabel.stringValue = title;
    self.progressBar.hidden = YES;
    self.cancelButton.title = @"Close";
    self.cancelButton.action = @selector(close);

    NSMutableArray<NSString *> *details = [NSMutableArray array];
    for (NSString *text in @[error.localizedDescription ?: @"",
                             error.localizedFailureReason ?: @"",
                             error.localizedRecoverySuggestion ?: @""]) {
        if (text.length > 0 && ![details containsObject:text]) [details addObject:text];
    }

    NSMutableDictionary *userInfo = [@{
        NSLocalizedDescriptionKey: title,
        NSUnderlyingErrorKey: error,
    } mutableCopy];
    if (details.count > 0) {
        userInfo[NSLocalizedRecoverySuggestionErrorKey] = [details componentsJoinedByString:@"\n\n"];
    }
    self.presentedError = [NSError errorWithDomain:error.domain
                                              code:error.code
                                          userInfo:userInfo];

    [self presentError:self.presentedError
        modalForWindow:self.window
              delegate:self
    didPresentSelector:@selector(didPresentErrorWithRecovery:contextInfo:)
           contextInfo:NULL];
}

- (void)didPresentErrorWithRecovery:(BOOL)didRecover contextInfo:(void *)contextInfo {
    [self close];
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
