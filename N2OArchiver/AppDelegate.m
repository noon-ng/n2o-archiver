#import "AppDelegate.h"
#import "NAPluginManager.h"
#import "NAExtractionWindowController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface AppDelegate ()
@property (nonatomic, strong) NSMutableArray<NAExtractionWindowController *> *windowControllers;
@property (nonatomic, assign) NSUInteger openPanelCount;
@property (nonatomic, assign) BOOL terminationPending;
@end

@implementation AppDelegate

- (instancetype)init {
    self = [super init];
    if (self) {
        _pluginDirectoryURLs = [NAPluginManager defaultPluginDirectoryURLs];
    }
    return self;
}

- (void)applicationWillFinishLaunching:(NSNotification *)notification {
    self.windowControllers = [NSMutableArray array];

    NAPluginManager *pm = [NAPluginManager sharedManager];

    [pm registerBuiltinExtractors];

    // Load external plugin bundles.
    [pm loadPluginsFromDirectoryURLs:self.pluginDirectoryURLs];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    // If launched without files (e.g. from Dock), show a file picker.
    if (self.windowControllers.count == 0) {
        [self openDocument:nil];
    }
}

- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {
    for (NSURL *url in urls) {
        if (url.isFileURL) [self extractFileAtURL:url];
    }
}

// The app keeps no state to restore, and secure coding is required from
// macOS 14 on.
- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)application {
    return YES;
}

- (IBAction)openDocument:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowsMultipleSelection = YES;
    panel.canChooseDirectories = NO;
    panel.canChooseFiles = YES;
    panel.message = NSLocalizedString(@"Select archives to extract",
                                      @"Prompt in the open panel");

    NSArray<UTType *> *types = [self allowedContentTypes];
    if (types.count > 0) panel.allowedContentTypes = types;

    self.openPanelCount++;
    [panel beginWithCompletionHandler:^(NSModalResponse result) {
        self.openPanelCount--;
        if (result == NSModalResponseOK) {
            for (NSURL *url in panel.URLs) {
                [self extractFileAtURL:url];
            }
        }
        [self terminateIfIdle];
    }];
}

// Quitting during an extraction cancels it and waits until the partial output
// has been removed; terminateIfIdle then replies to the pending termination.
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    NSArray<NAExtractionWindowController *> *working = [self workingControllers];
    if (working.count == 0) return NSTerminateNow;

    self.terminationPending = YES;
    for (NAExtractionWindowController *wc in working) {
        [wc cancelExtraction:nil];
    }
    return NSTerminateLater;
}

// Closing the open panel counts as closing the last window, and AppKit can
// terminate the app before the panel's completion handler runs and opens an
// extraction window. Termination is handled by terminateIfIdle instead.
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return NO;
}

#pragma mark - Private

// The types the open panel offers: every registered extractor's UTIs, plus a
// type for each of its extensions. Extensions the system has no type for
// (.lz, .zst, .ar) yield a dynamic type, which still filters by extension.
- (NSArray<UTType *> *)allowedContentTypes {
    NSMutableOrderedSet<UTType *> *types = [NSMutableOrderedSet orderedSet];
    for (Class<NAExtractorPlugin> cls in [[NAPluginManager sharedManager] allPluginClasses]) {
        for (NSString *identifier in [cls supportedUTIs]) {
            UTType *type = [UTType typeWithIdentifier:identifier];
            if (type) [types addObject:type];
        }
        for (NSString *extension in [cls supportedExtensions]) {
            UTType *type = [UTType typeWithFilenameExtension:extension];
            if (type) [types addObject:type];
        }
    }
    return types.array;
}

- (void)extractFileAtURL:(NSURL *)url {
    NAExtractionWindowController *wc =
        [[NAExtractionWindowController alloc] initWithArchiveURL:url];
    if (self.revealHandler) wc.revealHandler = self.revealHandler;
    [self.windowControllers addObject:wc];

    __weak typeof(self) weakSelf = self;
    __weak NAExtractionWindowController *weakWC = wc;
    __block id observer = [[NSNotificationCenter defaultCenter]
        addObserverForName:NSWindowWillCloseNotification
                    object:wc.window
                     queue:nil
                usingBlock:^(NSNotification *note) {
        [[NSNotificationCenter defaultCenter] removeObserver:observer];
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        if (weakWC) [s.windowControllers removeObject:weakWC];
        // Let the window finish closing before terminating.
        dispatch_async(dispatch_get_main_queue(), ^{
            [s terminateIfIdle];
        });
    }];

    [wc beginExtraction];
}

// Quits once no extraction windows remain and no open panel is showing, or,
// while a quit is pending, once no extraction is still working. Only the
// application's installed delegate terminates, so delegates created in tests
// do not end the test process.
- (void)terminateIfIdle {
    if (NSApp.delegate != self) return;

    if (self.terminationPending) {
        if ([self workingControllers].count > 0) return;
        self.terminationPending = NO;
        [NSApp replyToApplicationShouldTerminate:YES];
        return;
    }

    if (self.windowControllers.count > 0 || self.openPanelCount > 0) return;
    [NSApp terminate:nil];
}

- (NSArray<NAExtractionWindowController *> *)workingControllers {
    return [self.windowControllers filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(NAExtractionWindowController *wc,
                                              NSDictionary *bindings) {
            return wc.isWorking;
        }]];
}

@end
