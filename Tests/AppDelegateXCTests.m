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

#pragma mark - Quit

- (void)testQuitWhenIdleTerminatesNow {
    AppDelegate *delegate = [[AppDelegate alloc] init];
    [delegate applicationWillFinishLaunching:
        [NSNotification notificationWithName:NSApplicationWillFinishLaunchingNotification
                                      object:NSApp]];
    XCTAssertEqual([delegate applicationShouldTerminate:NSApp], NSTerminateNow,
                  @"quit with no extraction running should terminate immediately");
}

- (void)testQuitDuringExtractionCancelsAndWaits {
    AppDelegate *delegate = [[AppDelegate alloc] init];
    [delegate applicationWillFinishLaunching:
        [NSNotification notificationWithName:NSApplicationWillFinishLaunchingNotification
                                      object:NSApp]];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"n2o-quit-%u", arc4random()]];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *archive = [dir stringByAppendingPathComponent:@"test.zip"];
    [fm copyItemAtPath:[NATestFixtures pathForFixture:@"test.zip"] toPath:archive error:nil];

    [delegate application:NSApp openFile:archive];
    NSApplicationTerminateReply reply = [delegate applicationShouldTerminate:NSApp];
    XCTAssertEqual(reply, NSTerminateLater,
                  @"quit during extraction should wait for cleanup");

    NSDate *timeout = [NSDate dateWithTimeIntervalSinceNow:3.0];
    while ([[NSDate date] compare:timeout] == NSOrderedAscending) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }

    BOOL outputExists = [fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"test"]];
    [fm removeItemAtPath:dir error:nil];
    XCTAssertEqual([[delegate valueForKey:@"windowControllers"] count], 0u,
                  @"cancelled extraction windows should close");
    XCTAssertFalse(outputExists, @"quit during extraction should remove partial output");
}

@end
