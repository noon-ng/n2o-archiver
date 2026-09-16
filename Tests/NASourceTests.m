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

// Every NSLocalizedString key must be in the English table; otherwise the app
// shows the key and a translation has nothing to translate. Regenerate the
// table with `make strings`.
- (void)testEveryLocalizedStringIsInTheEnglishTable {
    NSString *sources = [[self repositoryPath] stringByAppendingPathComponent:@"N2OArchiver"];
    NSDictionary *table = [NSDictionary dictionaryWithContentsOfURL:
        [NSURL fileURLWithPath:[sources stringByAppendingPathComponent:
            @"Resources/en.lproj/Localizable.strings"]]];
    NAAssertNotNil(table, @"the English strings table should be readable");

    // NSLocalizedString(@"a" @"b", @"comment"): the key is every string
    // literal before the comma that ends the first argument.
    NSRegularExpression *call = [NSRegularExpression
        regularExpressionWithPattern:@"NSLocalizedString\\(\\s*((?:@\"(?:[^\"\\\\]|\\\\.)*\"\\s*)+),"
                             options:0 error:nil];
    NSRegularExpression *literal = [NSRegularExpression
        regularExpressionWithPattern:@"@\"((?:[^\"\\\\]|\\\\.)*)\""
                             options:0 error:nil];

    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    NSUInteger found = 0;
    for (NSString *item in [[NSFileManager defaultManager] enumeratorAtPath:sources]) {
        if (![item.pathExtension isEqualToString:@"m"]) continue;
        NSString *text = [NSString stringWithContentsOfFile:
            [sources stringByAppendingPathComponent:item] encoding:NSUTF8StringEncoding error:nil];

        for (NSTextCheckingResult *match in [call matchesInString:text options:0
                                                            range:NSMakeRange(0, text.length)]) {
            NSString *argument = [text substringWithRange:[match rangeAtIndex:1]];
            NSMutableString *key = [NSMutableString string];
            for (NSTextCheckingResult *part in [literal matchesInString:argument options:0
                                                                 range:NSMakeRange(0, argument.length)]) {
                [key appendString:[argument substringWithRange:[part rangeAtIndex:1]]];
            }
            found++;
            if (!table[key]) [missing addObject:key];
        }
    }

    NAAssertTrue(found > 20, @"the sources should use NSLocalizedString, found %lu calls",
                 (unsigned long)found);
    NAAssertEqualObjects(missing, @[], @"run `make strings`: keys missing from the English table");
}

@end
