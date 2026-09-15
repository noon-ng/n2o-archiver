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
        _pluginDirectories = [NAPluginManager defaultPluginDirectories];
    }
    return self;
}

- (void)applicationWillFinishLaunching:(NSNotification *)notification {
    self.windowControllers = [NSMutableArray array];

    NAPluginManager *pm = [NAPluginManager sharedManager];

    [pm registerBuiltinExtractors];

    // Load external plugin bundles.
    [pm loadPluginsFromDirectories:self.pluginDirectories];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    // If launched without files (e.g. from Dock), show a file picker.
    if (self.windowControllers.count == 0) {
        [self openDocument:nil];
    }
}

- (BOOL)application:(NSApplication *)sender openFile:(NSString *)filename {
    [self extractFile:filename];
    return YES;
}

- (void)application:(NSApplication *)sender openFiles:(NSArray<NSString *> *)filenames {
    for (NSString *path in filenames) {
        [self extractFile:path];
    }
    [sender replyToOpenOrPrint:NSApplicationDelegateReplySuccess];
}

- (IBAction)openDocument:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowsMultipleSelection = YES;
    panel.canChooseDirectories = NO;
    panel.canChooseFiles = YES;
    panel.message = @"Select archives to extract";

    // Build the allowed extensions from all registered plugins.
    NSMutableArray<NSString *> *extensions = [NSMutableArray array];
    for (Class<NAExtractorPlugin> cls in
         [[NAPluginManager sharedManager] allPluginClasses]) {
        [extensions addObjectsFromArray:[cls supportedExtensions]];
    }
    if (extensions.count > 0) {
        NSMutableArray<UTType *> *types = [NSMutableArray array];
        for (NSString *ext in extensions) {
            UTType *type = [UTType typeWithFilenameExtension:ext];
            if (type) [types addObject:type];
        }
        panel.allowedContentTypes = types;
    }

    self.openPanelCount++;
    [panel beginWithCompletionHandler:^(NSModalResponse result) {
        self.openPanelCount--;
        if (result == NSModalResponseOK) {
            for (NSURL *url in panel.URLs) {
                [self extractFile:url.path];
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

- (void)extractFile:(NSString *)path {
    NAExtractionWindowController *wc =
        [[NAExtractionWindowController alloc] initWithArchivePath:path];
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
