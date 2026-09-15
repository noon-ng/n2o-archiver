#import "NATestCase.h"
#import "NATestFixtures.h"
#import "NAWait.h"
#import "AppDelegate.h"
#import "NAPluginManager.h"
#import "Plugins/NALibarchiveExtractor.h"

@interface AppDelegateTests : NATestCase
@end

@implementation AppDelegateTests

#pragma mark - File open handling

- (void)testOpenFileReturnsYes {
    AppDelegate *delegate = [[AppDelegate alloc] init];
    // Trigger willFinishLaunching to set up internal state.
    [delegate applicationWillFinishLaunching:
        [NSNotification notificationWithName:NSApplicationWillFinishLaunchingNotification
                                      object:NSApp]];

    NSString *path = [NATestFixtures pathForFixture:@"test.zip"];
    BOOL handled = [delegate application:NSApp openFile:path];
    NAAssertTrue(handled, @"should accept a valid archive path");

    NAAssertTrue(NAWaitUntil(^BOOL { return [[delegate valueForKey:@"windowControllers"] count] == 0; }, 10.0),
                 @"the extraction window should close");

    // Clean up extraction output.
    NSString *expectedDir = [[NATestFixtures fixtureDir]
        stringByAppendingPathComponent:@"test"];
    [[NSFileManager defaultManager] removeItemAtPath:expectedDir error:nil];
}

#pragma mark - Plugin registration

- (void)testWillFinishLaunchingRegistersPlugins {
    AppDelegate *delegate = [[AppDelegate alloc] init];
    [delegate applicationWillFinishLaunching:
        [NSNotification notificationWithName:NSApplicationWillFinishLaunchingNotification
                                      object:NSApp]];

    NSArray *classes = [[NAPluginManager sharedManager] allPluginClasses];
    NAAssertTrue(classes.count >= 1,
                 @"at least one plugin should be registered after launch");
}

#pragma mark - Termination policy

// Closing the open panel counts as closing the last window, so AppKit's
// terminate-after-last-window-closed can quit before the panel's completion
// handler opens an extraction window. The delegate terminates explicitly.
- (void)testDoesNotUseTerminateAfterLastWindowClosed {
    AppDelegate *delegate = [[AppDelegate alloc] init];
    BOOL result = [delegate applicationShouldTerminateAfterLastWindowClosed:NSApp];
    NAAssertFalse(result, @"AppKit's last-window-closed termination should be disabled");
}

- (void)testClosedExtractionWindowIsReleased {
    AppDelegate *delegate = [[AppDelegate alloc] init];
    [delegate applicationWillFinishLaunching:
        [NSNotification notificationWithName:NSApplicationWillFinishLaunchingNotification
                                      object:NSApp]];

    NSString *path = [NATestFixtures pathForFixture:@"multi.zip"];
    [delegate application:NSApp openFile:path];
    NAAssertEqual([[delegate valueForKey:@"windowControllers"] count], 1u,
                  @"opening a file should add a window controller");

    NAAssertTrue(NAWaitUntil(^BOOL { return [[delegate valueForKey:@"windowControllers"] count] == 0; }, 10.0),
                 @"the extraction window should close");

    NAAssertEqual([[delegate valueForKey:@"windowControllers"] count], 0u,
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
    NAAssertEqual([delegate applicationShouldTerminate:NSApp], NSTerminateNow,
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
    NAAssertEqual(reply, NSTerminateLater,
                  @"quit during extraction should wait for cleanup");

    NAAssertTrue(NAWaitUntil(^BOOL { return [[delegate valueForKey:@"windowControllers"] count] == 0; }, 10.0),
                 @"the cancelled extraction windows should close");

    BOOL outputExists = [fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"test"]];
    [fm removeItemAtPath:dir error:nil];
    NAAssertEqual([[delegate valueForKey:@"windowControllers"] count], 0u,
                  @"cancelled extraction windows should close");
    NAAssertFalse(outputExists, @"quit during extraction should remove partial output");
}

#pragma mark - Info.plist

// Automatic termination can quit the app while no window is key, including
// during an extraction; the app quits on its own when idle instead.
- (void)testInfoPlistDoesNotOptIntoAutomaticTermination {
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:@"N2OArchiver/Info.plist"];
    NAAssertNotNil(plist, @"N2OArchiver/Info.plist should be readable from the repository root");
    NAAssertNil(plist[@"NSSupportsAutomaticTermination"],
                @"NSSupportsAutomaticTermination should not be set");
}

@end
