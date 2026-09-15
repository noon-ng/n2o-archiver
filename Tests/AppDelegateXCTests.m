#import <XCTest/XCTest.h>
#import "NATestFixtures.h"
#import "AppDelegate.h"
#import "NAPluginManager.h"
#import "Plugins/NALibarchiveExtractor.h"

@interface AppDelegateXCTests : XCTestCase
@end

@implementation AppDelegateXCTests

+ (void)setUp {
    [NATestFixtures setUp];
}

+ (void)tearDown {
    [NATestFixtures tearDown];
}

#pragma mark - File open handling

- (void)testOpenFileReturnsYes {
    AppDelegate *delegate = [[AppDelegate alloc] init];
    [delegate applicationWillFinishLaunching:
        [NSNotification notificationWithName:NSApplicationWillFinishLaunchingNotification
                                      object:NSApp]];

    NSString *path = [NATestFixtures pathForFixture:@"test.zip"];
    BOOL handled = [delegate application:NSApp openFile:path];
    XCTAssertTrue(handled);
}

#pragma mark - Plugin registration

- (void)testWillFinishLaunchingRegistersPlugins {
    AppDelegate *delegate = [[AppDelegate alloc] init];
    [delegate applicationWillFinishLaunching:
        [NSNotification notificationWithName:NSApplicationWillFinishLaunchingNotification
                                      object:NSApp]];

    NSArray *classes = [[NAPluginManager sharedManager] allPluginClasses];
    XCTAssertGreaterThanOrEqual(classes.count, 1u);
}

#pragma mark - Termination policy

// Closing the open panel counts as closing the last window, so AppKit's
// terminate-after-last-window-closed can quit before the panel's completion
// handler opens an extraction window. The delegate terminates explicitly.
- (void)testDoesNotUseTerminateAfterLastWindowClosed {
    AppDelegate *delegate = [[AppDelegate alloc] init];
    BOOL result = [delegate applicationShouldTerminateAfterLastWindowClosed:NSApp];
    XCTAssertFalse(result);
}

- (void)testClosedExtractionWindowIsReleased {
    AppDelegate *delegate = [[AppDelegate alloc] init];
    [delegate applicationWillFinishLaunching:
        [NSNotification notificationWithName:NSApplicationWillFinishLaunchingNotification
                                      object:NSApp]];

    NSString *path = [NATestFixtures pathForFixture:@"multi.zip"];
    [delegate application:NSApp openFile:path];
    XCTAssertEqual([[delegate valueForKey:@"windowControllers"] count], 1u,
                  @"opening a file should add a window controller");

    // Extraction window closes 0.5 s after completion.
    NSDate *timeout = [NSDate dateWithTimeIntervalSinceNow:3.0];
    while ([[NSDate date] compare:timeout] == NSOrderedAscending) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }

    XCTAssertEqual([[delegate valueForKey:@"windowControllers"] count], 0u,
                  @"window controller should be removed after its window closes");

    [[NSFileManager defaultManager] removeItemAtPath:
        [[NATestFixtures fixtureDir] stringByAppendingPathComponent:@"multi"] error:nil];
}

@end
