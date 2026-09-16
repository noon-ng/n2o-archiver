#import <Foundation/Foundation.h>
#import "NAExtractorPlugin.h"

NS_ASSUME_NONNULL_BEGIN

/// Signalled by tests to release a blocked scripted extraction.
extern dispatch_semaphore_t _Nullable NAScriptedRelease;

/// Extractor for files ending in .n2oscripted. Every mode first writes
/// payload.txt. By archive name:
/// - wait…: sets progress to 50% on payload.txt, then blocks until
///   NAScriptedRelease is signalled (succeeds) or the progress is cancelled
///   (fails with NSUserCancelledError)
/// - cancel-fail…: blocks until NAScriptedRelease is signalled, then fails
/// - fail…: fails
/// - immutable…: sets UF_IMMUTABLE on payload.txt, then fails
/// - long-error…: fails with 500 lines of tool output as the failure reason
/// - anything else: succeeds
@interface NATestScriptedExtractor : NSObject <NAExtractorPlugin>
@end

NS_ASSUME_NONNULL_END
