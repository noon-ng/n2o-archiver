#import "NATestCase.h"
#import "NATestFixtures.h"
#import "NATestScriptedExtractor.h"
#import "NAWait.h"
#import "NAExtractionJob.h"
#import "NAExtractionWindowController.h"
#import "NAPluginManager.h"
#import "Plugins/NALibarchiveExtractor.h"

// The extraction itself is tested in NAExtractionJobTests; these tests cover
// what the window shows and how it closes. The one test that reaches the
// Finder reveal replaces the reveal handler.

// Private methods under test.
@interface NAExtractionWindowController (Testing)
- (BOOL)windowShouldClose:(NSWindow *)sender;
- (void)toggleErrorDetails:(id)sender;
- (void)jobDidFinish:(NAExtractionJob *)job;
@end

@interface NAExtractionWindowControllerTests : NATestCase
@property (nonatomic, copy) NSString *workDir;
@end

@implementation NAExtractionWindowControllerTests

- (void)setUp {
    [super setUp];
    [[NAPluginManager sharedManager] registerExtractorClass:[NALibarchiveExtractor class]];
    [[NAPluginManager sharedManager] registerExtractorClass:[NATestScriptedExtractor class]];
    NAScriptedRelease = dispatch_semaphore_create(0);
    self.workDir = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"n2o-window-%u", arc4random()]];
    [[NSFileManager defaultManager] createDirectoryAtPath:self.workDir
                              withIntermediateDirectories:YES
                                               attributes:nil error:nil];
}

- (void)tearDown {
    [[NSFileManager defaultManager] removeItemAtPath:self.workDir error:nil];
    [super tearDown];
}

#pragma mark - Initialization

- (void)testWindowIsNamedAfterTheArchive {
    NSString *archive = [self copyFixture:@"test.zip" to:@"holiday photos.zip"];
    NAExtractionWindowController *wc = [[NAExtractionWindowController alloc] initWithArchiveURL:NAFileURL(archive)];

    NAAssertNotNil(wc.window, @"window should be created");
    NAAssertEqualObjects(wc.window.title, @"holiday photos.zip", @"the window should be named after the archive");
    NAAssertEqualObjects(wc.window.representedURL.path, archive,
                         @"the title bar should carry the archive's proxy icon");
    NAAssertEqualObjects([[wc valueForKey:@"filenameLabel"] stringValue], @"holiday photos.zip",
                         @"the window should show the archive name");
    NAAssertFalse(wc.isWorking, @"a new controller should not be working");
}

- (void)testConcurrentWindowsAreCascaded {
    NSString *archive = [self copyFixture:@"test.zip" to:@"test.zip"];
    NAExtractionWindowController *first = [[NAExtractionWindowController alloc] initWithArchiveURL:NAFileURL(archive)];
    NAExtractionWindowController *second = [[NAExtractionWindowController alloc] initWithArchiveURL:NAFileURL(archive)];

    NAAssertFalse(NSEqualPoints(first.window.frame.origin, second.window.frame.origin),
                  @"a second window should not cover the first, both at %@",
                  NSStringFromPoint(first.window.frame.origin));
}

- (void)testEscapeCancels {
    NSString *archive = [self writeFile:@"wait.n2oscripted"];
    NAExtractionWindowController *wc = [[NAExtractionWindowController alloc] initWithArchiveURL:NAFileURL(archive)];
    NSButton *cancel = [wc valueForKey:@"cancelButton"];

    NAAssertEqualObjects(cancel.keyEquivalent, @"\e", @"Esc should work the Cancel button");
    [wc beginExtraction];
    NAExtractionJob *job = [wc valueForKey:@"job"];
    [cancel performClick:nil];

    NAAssertTrue(job.state == NAExtractionJobStateCancelling ||
                 job.state == NAExtractionJobStateCancelled,
                 @"clicking Cancel should cancel the job, state %ld", (long)job.state);
    NAAssertTrue(NAWaitUntil(^BOOL { return !wc.isWorking && !wc.window.isVisible; }, 10.0),
                 @"the cancelled extraction should be cleaned up and its window closed");
    NAAssertFalse([self fileExists:@"wait"], @"output of the cancelled extraction should be removed");
}

#pragma mark - Extraction flow

- (void)testBeginExtractionCreatesOutputAndClosesWindow {
    NSString *archive = [self copyFixture:@"test.zip" to:@"test.zip"];
    NAExtractionWindowController *wc = [[NAExtractionWindowController alloc] initWithArchiveURL:NAFileURL(archive)];
    NSMutableArray<NSURL *> *revealed = [NSMutableArray array];
    wc.revealHandler = ^(NSURL *url) { [revealed addObject:url]; };

    [wc beginExtraction];
    NAAssertTrue(wc.window.isVisible, @"the window should be shown while extracting");
    NAAssertTrue(wc.isWorking, @"the controller should report work in progress");

    NAAssertTrue(NAWaitUntil(^BOOL { return !wc.isWorking; }, 10.0), @"extraction should finish");
    NAAssertTrue([self fileExists:@"test/a.txt"], @"extraction should create the output directory");
    NAAssertEqualObjects([[wc valueForKey:@"statusLabel"] stringValue], @"Done.",
                         @"the status should say the extraction is done");
    NAAssertEqualObjects([revealed valueForKey:@"path"],
                         @[[self.workDir stringByAppendingPathComponent:@"test"]],
                         @"the output folder should be revealed");
    NAAssertTrue(NAWaitUntil(^BOOL { return !wc.window.isVisible; }, 10.0),
                 @"the window should close after a successful extraction");
}

#pragma mark - Cancellation

- (void)testCancelKeepsWindowOpenUntilExtractionReturns {
    NSString *archive = [self writeFile:@"wait.n2oscripted"];
    NAExtractionWindowController *wc = [[NAExtractionWindowController alloc] initWithArchiveURL:NAFileURL(archive)];

    [wc beginExtraction];
    [wc cancelExtraction:nil];

    NSButton *button = [wc valueForKey:@"cancelButton"];
    NAAssertEqualObjects([[wc valueForKey:@"statusLabel"] stringValue], @"Cancelling…",
                         @"the status should say the extraction is being cancelled");
    NAAssertFalse(button.enabled, @"the Cancel button should be disabled while cancelling");
    NAAssertTrue(wc.window.isVisible, @"window should stay open until the extraction has returned");
    NAAssertTrue(wc.isWorking, @"controller should report work in progress");

    dispatch_semaphore_signal(NAScriptedRelease);
    NAAssertTrue(NAWaitUntil(^BOOL { return !wc.isWorking && !wc.window.isVisible; }, 10.0),
                 @"the cancelled extraction should be cleaned up and its window closed");
    NAAssertFalse([self fileExists:@"wait"], @"output of the cancelled extraction should be removed");
}

- (void)testClosingWindowDuringExtractionCancels {
    NSString *archive = [self writeFile:@"wait.n2oscripted"];
    NAExtractionWindowController *wc = [[NAExtractionWindowController alloc] initWithArchiveURL:NAFileURL(archive)];

    [wc beginExtraction];
    NAAssertFalse([wc windowShouldClose:wc.window], @"window should not close while extracting");
    dispatch_semaphore_signal(NAScriptedRelease);

    NAAssertTrue(NAWaitUntil(^BOOL { return !wc.isWorking && !wc.window.isVisible; }, 10.0),
                 @"the cancelled extraction should be cleaned up and its window closed");
    NAAssertFalse([self fileExists:@"wait"], @"closing during extraction should remove the output");
}

- (void)testLowFreeSpaceStopIsShownAsError {
    NSString *archive = [self writeFile:@"wait-space.n2oscripted"];
    NAExtractionWindowController *wc = [[NAExtractionWindowController alloc] initWithArchiveURL:NAFileURL(archive)];

    [wc beginExtraction];
    NAExtractionJob *job = [wc valueForKey:@"job"];
    job.spaceIsLow = ^BOOL(NSURL *url) { return YES; };
    NAAssertTrue(NAWaitUntil(^BOOL { return job.state == NAExtractionJobStateCancelling; }, 10.0),
                 @"low free space should stop the extraction");
    dispatch_semaphore_signal(NAScriptedRelease);

    NAAssertTrue(NAWaitUntil(^BOOL { return !wc.isWorking && wc.window.attachedSheet != nil; }, 10.0),
                 @"the reason for stopping should be presented");
    NSError *shown = [wc valueForKey:@"presentedError"];
    NAAssertTrue([shown.localizedRecoverySuggestion containsString:@"almost full"],
                 @"the sheet should say the disk is almost full, got %@", shown.localizedRecoverySuggestion);
    [self dismissSheetOf:wc];
}

#pragma mark - Error presentation

- (void)testUnsupportedFormatShowsError {
    NSString *archive = [self writeFile:@"notes.txt"];
    NAExtractionWindowController *wc = [[NAExtractionWindowController alloc] initWithArchiveURL:NAFileURL(archive)];

    [wc beginExtraction];
    NAAssertFalse(wc.isWorking, @"an unrecognized file should not start an extraction");
    NAAssertNotNil(wc.window.attachedSheet, @"the error should be shown at once");

    NSButton *button = [wc valueForKey:@"cancelButton"];
    NSTextField *status = [wc valueForKey:@"statusLabel"];
    NAAssertEqualObjects(button.title, @"Close", @"the button should offer Close after an error");
    NAAssertTrue([status.stringValue containsString:@"could not be extracted"],
                 @"the status should show the error, got %@", status.stringValue);
    [self dismissSheetOf:wc];
}

- (void)testErrorIsPresentedAsSheetWithDetails {
    NSString *archive = [self copyFixture:@"corrupt.zip" to:@"broken.zip"];
    NAExtractionWindowController *wc = [[NAExtractionWindowController alloc] initWithArchiveURL:NAFileURL(archive)];

    [wc beginExtraction];
    NAAssertTrue(NAWaitUntil(^BOOL { return !wc.isWorking && wc.window.attachedSheet != nil; }, 10.0),
                 @"the error should be presented as a sheet on the extraction window");

    NSError *shown = [wc valueForKey:@"presentedError"];
    NAAssertTrue([shown.localizedDescription containsString:@"“broken.zip” could not be extracted"],
                 @"the sheet title should name the archive, got %@", shown.localizedDescription);
    NAAssertTrue([shown.localizedRecoverySuggestion containsString:@"Unrecognized archive format"],
                 @"the sheet should show the extractor's message in full, got %@",
                 shown.localizedRecoverySuggestion);
    [self dismissSheetOf:wc];
}

- (void)testQuarantineFailureAfterSuccessHasItsOwnTitle {
    NSString *archive = [self copyFixture:@"test.zip" to:@"test.zip"];
    NAExtractionWindowController *wc = [[NAExtractionWindowController alloc] initWithArchiveURL:NAFileURL(archive)];
    NAExtractionJob *job = [[NAExtractionJob alloc] initWithArchiveURL:NAFileURL(archive)
                                                          pluginManager:[NAPluginManager sharedManager]];
    [job setValue:@(NAExtractionJobStateSucceeded) forKey:@"state"];
    [job setValue:[NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteUnknownError
                                  userInfo:@{NSLocalizedDescriptionKey: @"Not marked."}]
           forKey:@"error"];

    [wc showWindow:nil];
    [wc jobDidFinish:job];

    NSError *shown = [wc valueForKey:@"presentedError"];
    NAAssertTrue([shown.localizedDescription containsString:@"was extracted, but some files are not marked"],
                 @"the title should say the files were extracted, got %@", shown.localizedDescription);
    [self dismissSheetOf:wc];
}

- (void)testLongErrorDetailsAreCollapsedAndScrollable {
    NSString *archive = [self writeFile:@"long-error.n2oscripted"];
    NAExtractionWindowController *wc = [[NAExtractionWindowController alloc] initWithArchiveURL:NAFileURL(archive)];

    [wc beginExtraction];
    NAAssertTrue(NAWaitUntil(^BOOL { return !wc.isWorking && wc.window.attachedSheet != nil; }, 10.0),
                 @"the failure should be presented");

    NSAlert *alert = [wc valueForKey:@"errorAlert"];
    NSScrollView *details = [wc valueForKey:@"errorDetailsScrollView"];
    CGFloat screenHeight = NSHeight(NSScreen.mainScreen.visibleFrame);
    NAAssertTrue(alert != nil && details != nil, @"long output should be in a details area");
    NAAssertTrue(details.hidden, @"the details area should start collapsed");
    NAAssertTrue([[(NSTextView *)details.documentView string] containsString:@"file-500.bin"],
                 @"the details area should hold the full output");
    NAAssertTrue(NSHeight(wc.window.attachedSheet.frame) < 400,
                 @"the collapsed sheet should be short, got %.0f", NSHeight(wc.window.attachedSheet.frame));

    [wc toggleErrorDetails:nil];
    NAAssertFalse(details.hidden, @"Show Details should expand the details area");
    NAAssertTrue(NSHeight(wc.window.attachedSheet.frame) < MIN(600, screenHeight),
                 @"the expanded sheet should stay within a fixed height, got %.0f",
                 NSHeight(wc.window.attachedSheet.frame));
    NAAssertTrue(NSHeight(details.frame) < NSHeight(details.documentView.frame),
                 @"the output should scroll inside the details area");
    [self dismissSheetOf:wc];
}

#pragma mark - Helpers

// Dismisses the error sheet and checks that the window closes with it.
- (void)dismissSheetOf:(NAExtractionWindowController *)wc {
    if (!wc.window.attachedSheet) return;
    [wc.window endSheet:wc.window.attachedSheet returnCode:NSAlertFirstButtonReturn];
    NAAssertTrue(NAWaitUntil(^BOOL { return !wc.window.isVisible; }, 10.0),
                 @"dismissing the error should close the window");
}

- (NSString *)copyFixture:(NSString *)fixture to:(NSString *)name {
    NSString *path = [self.workDir stringByAppendingPathComponent:name];
    [[NSFileManager defaultManager] copyItemAtPath:[NATestFixtures pathForFixture:fixture]
                                            toPath:path error:nil];
    return path;
}

- (NSString *)writeFile:(NSString *)name {
    NSString *path = [self.workDir stringByAppendingPathComponent:name];
    [name writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
    return path;
}

- (BOOL)fileExists:(NSString *)relativePath {
    return [[NSFileManager defaultManager] fileExistsAtPath:
        [self.workDir stringByAppendingPathComponent:relativePath]];
}

@end
