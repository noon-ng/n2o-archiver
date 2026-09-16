#import "NAMainMenu.h"

@implementation NAMainMenu

+ (NSMenu *)menuWithServicesMenu:(NSMenu **)servicesMenuOut
                      windowMenu:(NSMenu **)windowMenuOut {
    // The product name is not translated; the menu titles around it are.
    NSString *appName = @"N2O Archiver";
    NSMenu *mainMenu = [[NSMenu alloc] init];

    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:appName];
    [appMenu addItemWithTitle:[NSString stringWithFormat:
                                  NSLocalizedString(@"About %@", @"Menu item; %@ is the app name"), appName]
                       action:@selector(orderFrontStandardAboutPanel:)
                keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];

    NSString *servicesTitle = NSLocalizedString(@"Services", @"Menu holding the system services");
    NSMenu *servicesMenu = [[NSMenu alloc] initWithTitle:servicesTitle];
    [appMenu addItemWithTitle:servicesTitle action:NULL keyEquivalent:@""].submenu = servicesMenu;
    [appMenu addItem:[NSMenuItem separatorItem]];

    [appMenu addItemWithTitle:[NSString stringWithFormat:
                                  NSLocalizedString(@"Hide %@", @"Menu item; %@ is the app name"), appName]
                       action:@selector(hide:)
                keyEquivalent:@"h"];
    NSMenuItem *hideOthers = [appMenu addItemWithTitle:NSLocalizedString(@"Hide Others", @"Menu item")
                                                action:@selector(hideOtherApplications:)
                                         keyEquivalent:@"h"];
    hideOthers.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
    [appMenu addItemWithTitle:NSLocalizedString(@"Show All", @"Menu item")
                       action:@selector(unhideAllApplications:)
                keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:[NSString stringWithFormat:
                                  NSLocalizedString(@"Quit %@", @"Menu item; %@ is the app name"), appName]
                       action:@selector(terminate:)
                keyEquivalent:@"q"];
    [mainMenu addItemWithTitle:appName action:NULL keyEquivalent:@""].submenu = appMenu;

    NSString *fileTitle = NSLocalizedString(@"File", @"Menu title");
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:fileTitle];
    [fileMenu addItemWithTitle:NSLocalizedString(@"Open…", @"Menu item that shows the open panel")
                        action:@selector(openDocument:)
                 keyEquivalent:@"o"];
    [fileMenu addItem:[NSMenuItem separatorItem]];
    [fileMenu addItemWithTitle:NSLocalizedString(@"Close", @"Menu item that closes the window")
                        action:@selector(performClose:)
                 keyEquivalent:@"w"];
    [mainMenu addItemWithTitle:fileTitle action:NULL keyEquivalent:@""].submenu = fileMenu;

    // The error sheet's details area is selectable text, so Copy and Select
    // All apply to it.
    NSString *editTitle = NSLocalizedString(@"Edit", @"Menu title");
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:editTitle];
    [editMenu addItemWithTitle:NSLocalizedString(@"Copy", @"Menu item")
                        action:@selector(copy:)
                 keyEquivalent:@"c"];
    [editMenu addItemWithTitle:NSLocalizedString(@"Select All", @"Menu item")
                        action:@selector(selectAll:)
                 keyEquivalent:@"a"];
    [mainMenu addItemWithTitle:editTitle action:NULL keyEquivalent:@""].submenu = editMenu;

    NSString *windowTitle = NSLocalizedString(@"Window", @"Menu title");
    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:windowTitle];
    [windowMenu addItemWithTitle:NSLocalizedString(@"Minimize", @"Menu item")
                          action:@selector(performMiniaturize:)
                   keyEquivalent:@"m"];
    [windowMenu addItemWithTitle:NSLocalizedString(@"Zoom", @"Menu item")
                          action:@selector(performZoom:)
                   keyEquivalent:@""];
    [windowMenu addItem:[NSMenuItem separatorItem]];
    [windowMenu addItemWithTitle:NSLocalizedString(@"Bring All to Front", @"Menu item")
                          action:@selector(arrangeInFront:)
                   keyEquivalent:@""];
    [mainMenu addItemWithTitle:windowTitle action:NULL keyEquivalent:@""].submenu = windowMenu;

    if (servicesMenuOut) *servicesMenuOut = servicesMenu;
    if (windowMenuOut) *windowMenuOut = windowMenu;
    return mainMenu;
}

@end
