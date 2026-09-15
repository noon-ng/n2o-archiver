#import "NAExtractionWindowController.h"
#import "NAPluginManager.h"
#include <sys/stat.h>

@interface NAExtractionWindowController ()
@property (nonatomic, copy) NSString *archivePath;
@property (nonatomic, strong) NSProgressIndicator *progressBar;
@property (nonatomic, strong) NSTextField *filenameLabel;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSButton *cancelButton;
@property (nonatomic, assign) BOOL cancelled;
@end

@implementation NAExtractionWindowController

- (instancetype)initWithArchivePath:(NSString *)archivePath {
    NSWindow *window = [self createWindow];
    self = [super initWithWindow:window];
    if (self) {
        _archivePath = [archivePath copy];
        _cancelled = NO;
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
        [self showErrorMessage:@"No plugin found that can handle this archive format."];
        return;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *dirError = nil;
    NSString *destPath = [self createDestinationForArchive:self.archivePath
                                                     error:&dirError];
    if (!destPath) {
        [self showErrorMessage:
            [NSString stringWithFormat:@"Cannot create destination: %@",
                dirError.localizedDescription]];
        return;
    }

    self.progressBar.doubleValue = 0.0;
    self.statusLabel.stringValue = @"Extracting…";

    __weak typeof(self) weakSelf = self;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        BOOL ok = [extractor extractArchiveAtPath:self.archivePath
                                    toDestination:destPath
                                         progress:^(double fraction, NSString *entry) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) s = weakSelf;
                if (!s || s.cancelled) return;
                s.progressBar.doubleValue = fraction * 100.0;
                s.statusLabel.stringValue = entry ?: @"";
            });
        }
                                            error:&error];

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) s = weakSelf;
            if (!s) return;

            if (s.cancelled) {
                // Clean up partial extraction. destPath was created by
                // createDestinationForArchive:, so it held nothing beforehand.
                [fm removeItemAtPath:destPath error:nil];
            } else if (ok) {
                [s extractionFinishedAtPath:destPath];
            } else {
                [s showErrorMessage:error.localizedDescription ?: @"Extraction failed."];
            }
        });
    });
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

// Creates a new, empty directory for the extraction: the archive's base name,
// or "<name> 2", "<name> 3", ... if that path is taken by any file or
// directory. mkdir fails with EEXIST instead of reusing an existing directory,
// so anything already on disk is never written into or removed on cancel.
- (nullable NSString *)createDestinationForArchive:(NSString *)archivePath
                                             error:(NSError **)error {
    NSString *base = [self destinationPathForArchive:archivePath];

    for (NSUInteger n = 1; ; n++) {
        NSString *candidate = (n == 1)
            ? base
            : [NSString stringWithFormat:@"%@ %lu", base, (unsigned long)n];

        if (mkdir(candidate.fileSystemRepresentation, 0755) == 0) {
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

    // Unwrap single-item directories: if the destination contains exactly one
    // top-level item and it's a directory, move its contents up.
    [self unwrapSingleItemDirectoryAtPath:destPath];

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

- (void)showErrorMessage:(NSString *)message {
    self.statusLabel.stringValue = message;
    self.progressBar.hidden = YES;
    self.cancelButton.title = @"Close";
    self.cancelButton.action = @selector(close);
}

#pragma mark - Actions

- (void)cancelExtraction:(id)sender {
    self.cancelled = YES;
    [self close];
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
