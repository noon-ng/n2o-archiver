#import <Foundation/Foundation.h>

// Provides paths to static test archives checked into Tests/Fixtures/.
// +setUp copies them to a temporary directory so tests can extract alongside
// without polluting the source tree. +tearDown removes the temporary copy.
@interface NATestFixtures : NSObject

+ (void)setUp;
+ (void)tearDown;
+ (NSString *)fixtureDir;
+ (NSString *)pathForFixture:(NSString *)name;

@end
