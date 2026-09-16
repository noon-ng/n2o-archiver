#import "NATestCase.h"
#import "NATestFixtures.h"
#import "NAWait.h"
#import "AppDelegate.h"
#import "NAPluginManager.h"
#import "Plugins/NALibarchiveExtractor.h"
#import "Plugins/NA7zExtractor.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface AppDelegate (Testing)
- (NSArray<UTType *> *)allowedContentTypes;

@end

@interface AppDelegateTests : NATestCase
@property (nonatomic, strong) NSMutableArray<NSString *> *revealed;
@end

@implementation AppDelegateTests

// A delegate that scans no plugin folders and does not reveal in Finder, after
// applicationWillFinishLaunching:. Revealed paths are recorded in revealed.
- (AppDelegate *)launchedDelegate {
    AppDelegate *delegate = [[AppDelegate alloc] init];
    delegate.pluginDirectories = @[];
    NSMutableArray<NSString *> *revealed = [NSMutableArray array];
    self.revealed = revealed;
    delegate.revealHandler = ^(NSString *path) { [revealed addObject:path]; };
    [delegate applicationWillFinishLaunching:
        [NSNotification notificationWithName:NSApplicationWillFinishLaunchingNotification
                                      object:NSApp]];
    return delegate;
}

#pragma mark - File open handling

- (void)testOpenFileReturnsYes {
    AppDelegate *delegate = [self launchedDelegate];

    NSString *path = [NATestFixtures pathForFixture:@"test.zip"];
    BOOL handled = [delegate application:NSApp openFile:path];
    NAAssertTrue(handled, @"should accept a valid archive path");

    NAAssertTrue(NAWaitUntil(^BOOL { return [[delegate valueForKey:@"windowControllers"] count] == 0; }, 10.0),
                 @"the extraction window should close");

    NSString *expectedDir = [[NATestFixtures fixtureDir]
        stringByAppendingPathComponent:@"test"];
    NAAssertEqualObjects(self.revealed, @[expectedDir],
                         @"the delegate's reveal handler should receive the output folder");
    [[NSFileManager defaultManager] removeItemAtPath:expectedDir error:nil];
}

#pragma mark - Plugin registration

- (void)testWillFinishLaunchingRegistersPlugins {
    [self launchedDelegate];

    NAAssertEqualObjects([[AppDelegate alloc] init].pluginDirectories,
                         [NAPluginManager defaultPluginDirectories],
                         @"a new delegate should scan the default plugin folders");
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
    AppDelegate *delegate = [self launchedDelegate];

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
    AppDelegate *delegate = [self launchedDelegate];
    NAAssertEqual([delegate applicationShouldTerminate:NSApp], NSTerminateNow,
                  @"quit with no extraction running should terminate immediately");
}

- (void)testQuitDuringExtractionCancelsAndWaits {
    AppDelegate *delegate = [self launchedDelegate];

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

#pragma mark - Document types

// Info.plist decides which files Finder offers the app for; the extractors'
// supportedUTIs decide what it can open. The two must name the same types.
- (void)testInfoPlistDocumentTypesAreTheExtractorsUTIs {
    NSMutableSet<NSString *> *declared = [NSMutableSet set];
    for (NSDictionary *type in [self infoPlist][@"CFBundleDocumentTypes"]) {
        [declared addObjectsFromArray:type[@"LSItemContentTypes"]];
    }

    NSMutableSet<NSString *> *supported = [NSMutableSet set];
    for (Class<NAExtractorPlugin> cls in @[[NA7zExtractor class], [NALibarchiveExtractor class]]) {
        [supported addObjectsFromArray:[cls supportedUTIs]];
    }

    NAAssertEqualObjects(declared, supported,
                         @"Info.plist and the built-in extractors should name the same types");
}

- (void)testSupportedUTIsAreArchiveTypesTheSystemKnows {
    for (Class<NAExtractorPlugin> cls in @[[NA7zExtractor class], [NALibarchiveExtractor class]]) {
        for (NSString *identifier in [cls supportedUTIs]) {
            UTType *type = [UTType typeWithIdentifier:identifier];
            NAAssertTrue(type.isDeclared, @"%@ should be a type the system declares", identifier);
            NAAssertTrue([type conformsToType:UTTypeArchive] || [type conformsToType:UTTypeDiskImage],
                         @"%@ should be an archive or disk image type", identifier);
        }
    }
}

- (void)testOpenPanelOffersEverySupportedExtensionAndType {
    AppDelegate *delegate = [self launchedDelegate];
    NSSet<UTType *> *offered = [NSSet setWithArray:[delegate allowedContentTypes]];

    for (Class<NAExtractorPlugin> cls in [[NAPluginManager sharedManager] allPluginClasses]) {
        for (NSString *extension in [cls supportedExtensions]) {
            UTType *type = [UTType typeWithFilenameExtension:extension];
            NAAssertTrue([offered containsObject:type],
                         @"the open panel should offer .%@ (%@)", extension, type.identifier);
        }
        for (NSString *identifier in [cls supportedUTIs]) {
            NAAssertTrue([offered containsObject:[UTType typeWithIdentifier:identifier]],
                         @"the open panel should offer %@", identifier);
        }
    }
}

#pragma mark - Info.plist

// Automatic termination can quit the app while no window is key, including
// during an extraction; the app quits on its own when idle instead.
- (void)testInfoPlistDoesNotOptIntoAutomaticTermination {
    NAAssertNil([self infoPlist][@"NSSupportsAutomaticTermination"],
                @"NSSupportsAutomaticTermination should not be set");
}

// The app's Info.plist as built. __FILE__ is Tests/AppDelegateTests.m relative
// to the repository root when built by make, and an absolute path under Xcode.
- (NSDictionary *)infoPlist {
    NSString *repository = [@(__FILE__) stringByDeletingLastPathComponent].stringByDeletingLastPathComponent;
    NSString *path = [repository stringByAppendingPathComponent:@"N2OArchiver/Info.plist"];
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:path];
    NAAssertNotNil(plist, @"%@ should be readable", path);
    return plist;
}

@end
