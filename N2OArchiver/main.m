#import <Cocoa/Cocoa.h>
#import "AppDelegate.h"

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;

        // Set up the main menu programmatically.
        NSMenu *mainMenu = [[NSMenu alloc] init];

        // Application menu
        NSMenuItem *appMenuItem = [[NSMenuItem alloc] init];
        [mainMenu addItem:appMenuItem];
        NSMenu *appMenu = [[NSMenu alloc] init];
        [appMenu addItemWithTitle:@"About N2O Archiver"
                           action:@selector(orderFrontStandardAboutPanel:)
                    keyEquivalent:@""];
        [appMenu addItem:[NSMenuItem separatorItem]];
        [appMenu addItemWithTitle:@"Quit N2O Archiver"
                           action:@selector(terminate:)
                    keyEquivalent:@"q"];
        appMenuItem.submenu = appMenu;

        // File menu
        NSMenuItem *fileMenuItem = [[NSMenuItem alloc] init];
        [mainMenu addItem:fileMenuItem];
        NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
        [fileMenu addItemWithTitle:@"Open…"
                            action:@selector(openDocument:)
                     keyEquivalent:@"o"];
        fileMenuItem.submenu = fileMenu;

        app.mainMenu = mainMenu;

        [app run];
    }
    return 0;
}
