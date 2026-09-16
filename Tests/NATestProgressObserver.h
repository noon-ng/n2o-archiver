#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Calls handler, on the thread that changed the progress, each time
/// fractionCompleted of progress changes. Observes until deallocated.
@interface NATestProgressObserver : NSObject

- (instancetype)initWithProgress:(NSProgress *)progress
                         handler:(void (^)(double fraction, NSURL *_Nullable fileURL))handler;

@end

NS_ASSUME_NONNULL_END
