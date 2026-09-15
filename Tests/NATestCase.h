// Test base class and assertion macros shared by both test runners.
//
// `make test` builds these tests into a standalone executable with the
// NATestRunner below, which needs no XCTest. The Xcode test target defines
// NA_XCTEST=1, which makes NATestCase an XCTestCase subclass and maps the
// NAAssert* macros onto XCTAssert*, so the same test files run under
// `xcodebuild test`.

#if NA_XCTEST

#import <XCTest/XCTest.h>

/// Copies the fixtures (NATestFixtures) before a test class runs and removes
/// them afterwards.
@interface NATestCase : XCTestCase
@end

#define NAAssertTrue(expr, ...) XCTAssertTrue(expr, __VA_ARGS__)
#define NAAssertFalse(expr, ...) XCTAssertFalse(expr, __VA_ARGS__)
#define NAAssertNil(expr, ...) XCTAssertNil(expr, __VA_ARGS__)
#define NAAssertNotNil(expr, ...) XCTAssertNotNil(expr, __VA_ARGS__)
#define NAAssertEqualObjects(a, b, ...) XCTAssertEqualObjects(a, b, __VA_ARGS__)
#define NAAssertEqual(a, b, ...) XCTAssertEqual(a, b, __VA_ARGS__)

#else

#import <Foundation/Foundation.h>

@interface NATestCase : NSObject
- (void)setUp;
- (void)tearDown;
@end

/// Runs every method whose name starts with "test" in each registered class,
/// in name order, calling setUp before and tearDown after each one, including
/// after a failure.
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

#endif
