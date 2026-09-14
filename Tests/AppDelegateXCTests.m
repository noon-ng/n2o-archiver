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

- (void)testShouldTerminateAfterLastWindowClosed {
    AppDelegate *delegate = [[AppDelegate alloc] init];
    XCTAssertTrue([delegate applicationShouldTerminateAfterLastWindowClosed:NSApp]);
}

@end
