#import "NAExtractionWindowController.h"
#import "NAExtractionJob.h"
#import "NAPluginManager.h"

@interface NAExtractionWindowController () <NSWindowDelegate>
@property (nonatomic, copy) NSString *archivePath;
@property (nonatomic, strong, nullable) NAExtractionJob *job;
@property (nonatomic, strong) NSProgressIndicator *progressBar;
@property (nonatomic, strong) NSTextField *filenameLabel;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSButton *cancelButton;
// The error shown in the sheet, as composed by presentError:title:.
@property (nonatomic, strong, nullable) NSError *presentedError;
@property (nonatomic, strong, nullable) NSAlert *errorAlert;
@property (nonatomic, strong, nullable) NSView *errorDetailsView;
@property (nonatomic, strong, nullable) NSScrollView *errorDetailsScrollView;
@property (nonatomic, strong, nullable) NSButton *errorDetailsButton;
@end

@implementation NAExtractionWindowController

- (instancetype)initWithArchivePath:(NSString *)archivePath {
    NSWindow *window = [self createWindow];
    self = [super initWithWindow:window];
    if (self) {
        _archivePath = [archivePath copy];
        _revealHandler = ^(NSString *path) {
            // Selects the output folder in its parent, rather than opening it.
            [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:
                @[[NSURL fileURLWithPath:path isDirectory:YES]]];
        };
        window.delegate = self;
        window.title = archivePath.lastPathComponent;
        // Gives the window the archive's proxy icon in its title bar.
        window.representedURL = [NSURL fileURLWithPath:archivePath];
        [self setupUI];
        self.filenameLabel.stringValue = archivePath.lastPathComponent;
    }
    return self;
}

- (void)beginExtraction {
    if (self.job) return;
    [self showWindow:nil];

    self.progressBar.doubleValue = 0.0;
    self.statusLabel.stringValue = @"Extracting…";

    NAExtractionJob *job = [[NAExtractionJob alloc] initWithArchivePath:self.archivePath
                                                          pluginManager:[NAPluginManager sharedManager]];
    __weak typeof(self) weakSelf = self;
    job.progressHandler = ^(double fraction, NSString *entry) {
        weakSelf.progressBar.doubleValue = fraction * 100.0;
        weakSelf.statusLabel.stringValue = entry;
    };
    // The job holds this block until it finishes, which keeps the controller
    // alive while an extraction is running.
    job.completionHandler = ^(NAExtractionJob *finished) {
        [self jobDidFinish:finished];
    };
    self.job = job;
    [job start];
}

- (BOOL)isWorking {
    return self.job.isActive;
}

- (void)jobDidFinish:(NAExtractionJob *)job {
    switch (job.state) {
        case NAExtractionJobStateSucceeded:
            if (job.error) {
                [self presentError:job.error
                             title:[NSString stringWithFormat:
                    @"“%@” was extracted, but some files are not marked as downloaded.",
                    self.archivePath.lastPathComponent]];
            } else {
                [self extractionFinishedAtPath:job.destinationPath];
            }
            break;
        case NAExtractionJobStateFailed:
            [self presentError:job.error title:[self failureTitle]];
            break;
        case NAExtractionJobStateCancelled:
            if (job.error) {
                [self presentError:job.error title:[self failureTitle]];
            } else {
                [self close];
            }
            break;
        default:
            break;
    }
}

#pragma mark - Completion

- (void)extractionFinishedAtPath:(NSString *)destPath {
    self.progressBar.doubleValue = 100.0;
    self.statusLabel.stringValue = @"Done.";

    self.revealHandler(destPath);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self close];
    });
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
    self.cancelButton.enabled = YES;

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
    if (!self.isWorking) {
        [self close];
        return;
    }
    if (self.job.state == NAExtractionJobStateCancelling) return;

    [self.job cancel];
    self.statusLabel.stringValue = @"Cancelling…";
    self.cancelButton.enabled = NO;
}

#pragma mark - NSWindowDelegate

// The close button cancels a running extraction; the window closes once the
// cancelled output has been removed.
- (BOOL)windowShouldClose:(NSWindow *)sender {
    if (!self.isWorking) return YES;
    [self cancelExtraction:sender];
    return NO;
}

#pragma mark - Window and UI setup

// Places the first window in the middle of the screen and each further window
// down and to the right of the one before, so concurrent extractions do not
// hide one another.
static NSPoint NANextWindowTopLeft = {0, 0};

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

    if (NSEqualPoints(NANextWindowTopLeft, NSZeroPoint)) {
        [window center];
        NANextWindowTopLeft = NSMakePoint(NSMinX(window.frame), NSMaxY(window.frame));
    }
    NANextWindowTopLeft = [window cascadeTopLeftFromPoint:NANextWindowTopLeft];
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
    // Esc cancels the extraction, as it dismisses a sheet.
    self.cancelButton.keyEquivalent = @"\e";
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
