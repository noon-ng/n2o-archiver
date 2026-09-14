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

- (void)testShouldTerminateAfterLastWindowClosed {
    AppDelegate *delegate = [[AppDelegate alloc] init];
    BOOL result = [delegate applicationShouldTerminateAfterLastWindowClosed:NSApp];
    NAAssertTrue(result, @"app should terminate after last window closes");
}

@end
