#import <Cocoa/Cocoa.h>
#import "AppDelegate.h"
#import "NAMainMenu.h"

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;

        NSMenu *servicesMenu = nil;
        NSMenu *windowMenu = nil;
        app.mainMenu = [NAMainMenu menuWithServicesMenu:&servicesMenu windowMenu:&windowMenu];
        app.servicesMenu = servicesMenu;
        app.windowsMenu = windowMenu;

        [app run];
    }
    return 0;
}
