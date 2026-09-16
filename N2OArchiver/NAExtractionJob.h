#import <Foundation/Foundation.h>
#import "NAPluginManager.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, NAExtractionJobState) {
    NAExtractionJobStatePending,
    NAExtractionJobStateExtracting,
    NAExtractionJobStateCancelling,
    NAExtractionJobStateSucceeded,
    NAExtractionJobStateFailed,
    NAExtractionJobStateCancelled,
};

/// Extracts one archive next to itself.
///
/// The job picks an extractor from its plugin manager, extracts into a hidden
/// `.n2o-extract-<UUID>` directory on a dispatch queue, marks the output with
/// the archive's quarantine value, unwraps a single top-level directory, and
/// renames the directory to the archive's base name (`<name> 2`, … if taken).
/// The output of a failed or cancelled extraction is removed.
/// While extracting it holds a process activity and stops when free space on
/// the destination volume runs low. start, cancel and all handlers run on the
/// main queue.
@interface NAExtractionJob : NSObject

- (instancetype)initWithArchiveURL:(NSURL *)archiveURL
                     pluginManager:(NAPluginManager *)pluginManager NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly, copy) NSURL *archiveURL;
@property (nonatomic, readonly) NAExtractionJobState state;

/// YES while extracting or cancelling, until cancelled output has been removed.
@property (nonatomic, readonly, getter=isActive) BOOL active;

/// The visible output directory, set when the job succeeded.
@property (nonatomic, readonly, copy, nullable) NSURL *destinationURL;

/// Failed: why. Succeeded: some items could not be marked as downloaded, or
/// nil. Cancelled: the reason when the job stopped itself (low free space),
/// or nil when cancel was called.
@property (nonatomic, readonly, strong, nullable) NSError *error;

/// Called on the main queue, at most every 0.1 s and only when something
/// changed, with the fraction done and the name of the item being written.
@property (nonatomic, copy, nullable) void (^progressHandler)(double fraction, NSString *entry);

/// Called once on the main queue when the job reaches a final state.
@property (nonatomic, copy, nullable) void (^completionHandler)(NAExtractionJob *job);

/// Returns YES when free space on the volume holding url is low. Checked
/// every 0.1 s while extracting. Defaults to
/// statfs with +isFreeSpaceLowWithAvailable:total:; replaceable in tests.
@property (nonatomic, copy) BOOL (^spaceIsLow)(NSURL *url);

/// YES when available bytes are below the smaller of 1 GB and 5% of total.
+ (BOOL)isFreeSpaceLowWithAvailable:(uint64_t)available total:(uint64_t)total;

/// Starts the job. Has no effect unless the job is pending.
- (void)start;

/// Stops extraction and removes its output. A pending job becomes cancelled
/// at once; a job that has already finished extracting is not affected.
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
