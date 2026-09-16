#import "NATestCase.h"

// Checks on the app's own source files. __FILE__ is Tests/NASourceTests.m
// relative to the repository root when built by make, and an absolute path
// under Xcode.
@interface NASourceTests : NATestCase
@end

@implementation NASourceTests

- (NSString *)repositoryPath {
    return [@(__FILE__) stringByDeletingLastPathComponent].stringByDeletingLastPathComponent;
}

// Messages go to os_log (NALog.h), which redacts file paths unless private
// data logging is enabled for the subsystem; NSLog would print them to the
// system log for everyone.
- (void)testAppSourcesLogThroughOSLog {
    NSString *sources = [[self repositoryPath] stringByAppendingPathComponent:@"N2OArchiver"];
    NSMutableArray<NSString *> *offenders = [NSMutableArray array];

    for (NSString *item in [[NSFileManager defaultManager] enumeratorAtPath:sources]) {
        if (![item.pathExtension isEqualToString:@"m"] && ![item.pathExtension isEqualToString:@"h"]) {
            continue;
        }
        NSString *text = [NSString stringWithContentsOfFile:
            [sources stringByAppendingPathComponent:item] encoding:NSUTF8StringEncoding error:nil];
        if ([text containsString:@"NSLog("]) [offenders addObject:item];
    }

    NAAssertEqualObjects(offenders, @[], @"app sources should log with os_log, not NSLog");
}

@end
