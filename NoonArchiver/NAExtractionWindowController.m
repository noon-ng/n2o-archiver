#import "NAExtractionWindowController.h"
#import "NAPluginManager.h"

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

    NSString *destPath = [self destinationPathForArchive:self.archivePath];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *dirError = nil;
    if (![fm createDirectoryAtPath:destPath
       withIntermediateDirectories:YES
                        attributes:nil
                             error:&dirError]) {
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
                // Clean up partial extraction.
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
    NSError *error = nil;
    NSArray<NSString *> *items =
        [fm contentsOfDirectoryAtPath:destPath error:&error];

    // Filter out hidden files (e.g. .DS_Store).
    NSMutableArray<NSString *> *visible = [NSMutableArray array];
    for (NSString *item in items) {
        if (![item hasPrefix:@"."]) [visible addObject:item];
    }

    if (visible.count != 1) return;

    NSString *singleItem = [destPath stringByAppendingPathComponent:visible[0]];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:singleItem isDirectory:&isDir] || !isDir) return;

    // Move inner contents up into destPath.
    NSArray<NSString *> *inner =
        [fm contentsOfDirectoryAtPath:singleItem error:nil];
    for (NSString *child in inner) {
        NSString *src = [singleItem stringByAppendingPathComponent:child];
        NSString *dst = [destPath stringByAppendingPathComponent:child];
        [fm moveItemAtPath:src toPath:dst error:nil];
    }
    [fm removeItemAtPath:singleItem error:nil];
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
    window.title = @"NoonArchiver";
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
