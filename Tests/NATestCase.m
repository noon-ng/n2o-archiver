#import "NATestCase.h"
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

        if (testMethods.count == 0) continue;

        NSString *className = NSStringFromClass(cls);
        fprintf(stderr, "\n--- %s (%lu tests) ---\n",
                className.UTF8String, (unsigned long)testMethods.count);

        for (NSString *methodName in testMethods) {
            totalRun++;
            NATestCase *instance = [[cls alloc] init];
            @try {
                [instance setUp];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [instance performSelector:NSSelectorFromString(methodName)];
#pragma clang diagnostic pop
                [instance tearDown];
                totalPassed++;
                fprintf(stderr, "  PASS: %s\n", methodName.UTF8String);
            } @catch (NSException *e) {
                totalFailed++;
                fprintf(stderr, "  FAIL: %s — %s\n",
                        methodName.UTF8String, e.reason.UTF8String);
            }
        }
    }

    fprintf(stderr, "\n=== %d tests: %d passed, %d failed ===\n",
            totalRun, totalPassed, totalFailed);
    return totalFailed > 0 ? 1 : 0;
}

@end
