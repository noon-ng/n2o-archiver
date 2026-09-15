#import "NATestCase.h"
#import "NATestFixtures.h"

#if NA_XCTEST

@implementation NATestCase

+ (void)setUp {
    [super setUp];
    [NATestFixtures setUp];
}

+ (void)tearDown {
    [NATestFixtures tearDown];
    [super tearDown];
}

@end

#else

#import <objc/runtime.h>

@implementation NATestCase
- (void)setUp {}
- (void)tearDown {}
@end

static NSMutableArray<Class> *_registeredClasses;

@implementation NATestRunner

+ (void)initialize {
    _registeredClasses = [NSMutableArray array];
}

+ (void)registerTestClass:(Class)cls {
    [_registeredClasses addObject:cls];
}

+ (int)runAllTests {
    int totalPassed = 0;
    int totalFailed = 0;
    int totalRun = 0;

    for (Class cls in _registeredClasses) {
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);

        NSMutableArray<NSString *> *testMethods = [NSMutableArray array];
        for (unsigned int i = 0; i < methodCount; i++) {
            NSString *name = NSStringFromSelector(method_getName(methods[i]));
            if ([name hasPrefix:@"test"] && method_getNumberOfArguments(methods[i]) == 2) {
                [testMethods addObject:name];
            }
        }
        free(methods);
        // class_copyMethodList returns methods in no defined order.
        [testMethods sortUsingSelector:@selector(compare:)];

        if (testMethods.count == 0) continue;

        NSString *className = NSStringFromClass(cls);
        fprintf(stderr, "\n--- %s (%lu tests) ---\n",
                className.UTF8String, (unsigned long)testMethods.count);

        for (NSString *methodName in testMethods) {
            totalRun++;
            NATestCase *instance = [[cls alloc] init];
            NSString *failure = nil;
            @try {
                [instance setUp];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [instance performSelector:NSSelectorFromString(methodName)];
#pragma clang diagnostic pop
            } @catch (NSException *e) {
                failure = e.reason ?: e.name;
            } @finally {
                // tearDown runs after failures too, so temporary files are removed.
                @try {
                    [instance tearDown];
                } @catch (NSException *e) {
                    if (!failure) failure = [@"tearDown: " stringByAppendingString:e.reason ?: e.name];
                }
            }

            if (failure) {
                totalFailed++;
                fprintf(stderr, "  FAIL: %s — %s\n", methodName.UTF8String, failure.UTF8String);
            } else {
                totalPassed++;
                fprintf(stderr, "  PASS: %s\n", methodName.UTF8String);
            }
        }
    }

    fprintf(stderr, "\n=== %d tests: %d passed, %d failed ===\n",
            totalRun, totalPassed, totalFailed);
    return totalFailed > 0 ? 1 : 0;
}

@end

#endif
