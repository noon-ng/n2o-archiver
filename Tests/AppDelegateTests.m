#import "NATestCase.h"
#import "NATestFixtures.h"
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

    // Wait for extraction.
    NSDate *timeout = [NSDate dateWithTimeIntervalSinceNow:5.0];
    while ([[NSDate date] compare:timeout] == NSOrderedAscending) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }

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

    // Extraction window closes 0.5 s after completion.
    NSDate *timeout = [NSDate dateWithTimeIntervalSinceNow:3.0];
    while ([[NSDate date] compare:timeout] == NSOrderedAscending) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }

    NAAssertEqual([[delegate valueForKey:@"windowControllers"] count], 0u,
                  @"window controller should be removed after its window closes");

    [[NSFileManager defaultManager] removeItemAtPath:
        [[NATestFixtures fixtureDir] stringByAppendingPathComponent:@"multi"] error:nil];
}

@end
