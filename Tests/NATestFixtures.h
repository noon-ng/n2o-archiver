#import <Foundation/Foundation.h>

// Creates sample archives in a temporary directory for testing.
// Call +setUp to create, +tearDown to clean up, +fixtureDir for the path.
@interface NATestFixtures : NSObject

+ (void)setUp;
+ (void)tearDown;
+ (NSString *)fixtureDir;
+ (NSString *)pathForFixture:(NSString *)name;

@end
