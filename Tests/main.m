#import <Cocoa/Cocoa.h>
#import "NATestCase.h"
#import "NATestFixtures.h"

// Import test classes so they link in.
#import "NALibarchiveExtractorTests.m"
#import "NAPluginManagerTests.m"
#import "NAExtractionJobTests.m"
#import "NAExtractionWindowControllerTests.m"
#import "AppDelegateTests.m"
#import "NA7zExtractorTests.m"
#import "NAQuarantineTests.m"

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        // NSApplication is needed for window controller tests.
        [NSApplication sharedApplication];

        fprintf(stderr, "Setting up test fixtures...\n");
        [NATestFixtures setUp];

        [NATestRunner registerTestClass:[NALibarchiveExtractorTests class]];
        [NATestRunner registerTestClass:[NAPluginManagerTests class]];
        [NATestRunner registerTestClass:[NAExtractionJobTests class]];
        [NATestRunner registerTestClass:[NAExtractionWindowControllerTests class]];
        [NATestRunner registerTestClass:[AppDelegateTests class]];
        [NATestRunner registerTestClass:[NA7zExtractorTests class]];
        [NATestRunner registerTestClass:[NAQuarantineTests class]];

        int result = [NATestRunner runAllTests];

        [NATestFixtures tearDown];
        return result;
    }
}
