#import <Foundation/Foundation.h>

// Lightweight test harness that mirrors XCTest's API.
// When XCTest is available (Xcode), these classes can be swapped for real
// XCTestCase subclasses with no source changes to the test methods.

@interface NATestCase : NSObject
- (void)setUp;
- (void)tearDown;
@end

@interface NATestRunner : NSObject
+ (int)runAllTests;
+ (void)registerTestClass:(Class)cls;
@end

#define NAAssertTrue(expr, ...) do { \
    if (!(expr)) { \
        NSString *_msg = [NSString stringWithFormat:@"" __VA_ARGS__]; \
        if (_msg.length == 0) _msg = @#expr; \
        @throw [NSException exceptionWithName:@"NATestFailure" \
                reason:[NSString stringWithFormat:@"FAIL: %@ (%s:%d)", _msg, __FILE__, __LINE__] \
                userInfo:nil]; \
    } \
} while(0)

#define NAAssertFalse(expr, ...) NAAssertTrue(!(expr), __VA_ARGS__)

#define NAAssertNil(expr, ...) NAAssertTrue((expr) == nil, __VA_ARGS__)

#define NAAssertNotNil(expr, ...) NAAssertTrue((expr) != nil, __VA_ARGS__)

#define NAAssertEqualObjects(a, b, ...) NAAssertTrue([(a) isEqual:(b)], __VA_ARGS__)

#define NAAssertEqual(a, b, ...) NAAssertTrue((a) == (b), __VA_ARGS__)
