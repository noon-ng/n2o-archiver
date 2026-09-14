#import "AppDelegate.h"
#import "NAPluginManager.h"
#import "NAExtractionWindowController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface AppDelegate ()
@property (nonatomic, strong) NSMutableArray<NAExtractionWindowController *> *windowControllers;
@end

@implementation AppDelegate

- (void)applicationWillFinishLaunching:(NSNotification *)notification {
    self.windowControllers = [NSMutableArray array];

    NAPluginManager *pm = [NAPluginManager sharedManager];

    [pm registerBuiltinExtractors];

    // Load external plugin bundles.
    [pm loadPlugins];
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

    [panel beginWithCompletionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        for (NSURL *url in panel.URLs) {
            [self extractFile:url.path];
        }
    }];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

#pragma mark - Private

- (void)extractFile:(NSString *)path {
    NAExtractionWindowController *wc =
        [[NAExtractionWindowController alloc] initWithArchivePath:path];
    [self.windowControllers addObject:wc];
    [wc beginExtraction];
}

@end
