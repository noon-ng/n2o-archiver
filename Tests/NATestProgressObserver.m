#import "NATestProgressObserver.h"

static void *NATestProgressObserverContext = &NATestProgressObserverContext;

@implementation NATestProgressObserver {
    NSProgress *_progress;
    void (^_handler)(double, NSURL *);
}

- (instancetype)initWithProgress:(NSProgress *)progress
                         handler:(void (^)(double, NSURL *))handler {
    self = [super init];
    if (self) {
        _progress = progress;
        _handler = [handler copy];
        [progress addObserver:self
                   forKeyPath:@"fractionCompleted"
                      options:0
                      context:NATestProgressObserverContext];
    }
    return self;
}

- (void)dealloc {
    [_progress removeObserver:self forKeyPath:@"fractionCompleted" context:NATestProgressObserverContext];
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id> *)change
                       context:(void *)context {
    if (context != NATestProgressObserverContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    _handler(_progress.fractionCompleted, _progress.fileURL);
}

@end
