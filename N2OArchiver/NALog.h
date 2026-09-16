#import <Foundation/Foundation.h>
#include <os/log.h>

NS_ASSUME_NONNULL_BEGIN

/// The app's log handle (subsystem sh.n2o.archiver). Read the messages with
/// `log show --predicate 'subsystem == "sh.n2o.archiver"'`. File paths are
/// logged with %{private}@ or %{private}s, so they are redacted unless
/// private data logging is enabled for the subsystem.
static inline os_log_t NALog(void) {
    static os_log_t log;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create("sh.n2o.archiver", "general");
    });
    return log;
}

NS_ASSUME_NONNULL_END
