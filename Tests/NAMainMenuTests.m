#import "NATestCase.h"
#import "NAMainMenu.h"

@interface NAMainMenuTests : NATestCase
@end

@implementation NAMainMenuTests

- (NSMenuItem *)itemWithSelector:(SEL)selector inMenu:(NSMenu *)menu {
    for (NSMenuItem *item in menu.itemArray) {
        if (item.action == selector) return item;
        NSMenuItem *found = item.submenu ? [self itemWithSelector:selector inMenu:item.submenu] : nil;
        if (found) return found;
    }
    return nil;
}

- (void)testTopLevelMenus {
    NSMenu *menu = [NAMainMenu menuWithServicesMenu:NULL windowMenu:NULL];
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    for (NSMenuItem *item in menu.itemArray) [titles addObject:item.submenu.title];

    NAAssertEqualObjects(titles, (@[@"N2O Archiver", @"File", @"Edit", @"Window"]),
                         @"the main menu should have the standard menus, got %@", titles);
}

- (void)testStandardCommandsAndKeyEquivalents {
    NSMenu *menu = [NAMainMenu menuWithServicesMenu:NULL windowMenu:NULL];
    NSDictionary<NSString *, NSString *> *expected = @{
        @"orderFrontStandardAboutPanel:": @"",
        @"hide:": @"h",
        @"hideOtherApplications:": @"h",
        @"unhideAllApplications:": @"",
        @"terminate:": @"q",
        @"openDocument:": @"o",
        @"performClose:": @"w",
        @"copy:": @"c",
        @"selectAll:": @"a",
        @"performMiniaturize:": @"m",
        @"performZoom:": @"",
        @"arrangeInFront:": @"",
    };
    for (NSString *name in expected) {
        NSMenuItem *item = [self itemWithSelector:NSSelectorFromString(name) inMenu:menu];
        NAAssertNotNil(item, @"the menu should offer %@", name);
        NAAssertEqualObjects(item.keyEquivalent, expected[name],
                             @"%@ should have key equivalent “%@”", name, expected[name]);
    }

    NSMenuItem *hideOthers = [self itemWithSelector:@selector(hideOtherApplications:) inMenu:menu];
    NAAssertEqual(hideOthers.keyEquivalentModifierMask,
                  NSEventModifierFlagCommand | NSEventModifierFlagOption,
                  @"Hide Others should be Command-Option-H");
}

- (void)testServicesAndWindowMenusAreReturnedForNSApp {
    NSMenu *servicesMenu = nil;
    NSMenu *windowMenu = nil;
    NSMenu *menu = [NAMainMenu menuWithServicesMenu:&servicesMenu windowMenu:&windowMenu];

    NAAssertEqualObjects(servicesMenu.title, @"Services",
                         @"the Services menu should be returned for NSApp.servicesMenu");
    NAAssertEqualObjects(windowMenu.title, @"Window",
                         @"the Window menu should be returned for NSApp.windowsMenu");
    NAAssertEqualObjects(menu.itemArray.lastObject.submenu, windowMenu,
                         @"the returned Window menu should be the one in the main menu");
}

@end
