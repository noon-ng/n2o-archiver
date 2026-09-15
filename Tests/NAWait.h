#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs the current run loop in 10 ms steps until condition returns YES or
/// timeout seconds have passed. Returns YES if the condition became true.
BOOL NAWaitUntil(BOOL (^condition)(void), NSTimeInterval timeout);

NS_ASSUME_NONNULL_END
