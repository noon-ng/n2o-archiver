#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const NAQuarantineErrorDomain;

typedef NS_ERROR_ENUM(NAQuarantineErrorDomain, NAQuarantineError) {
    /// Some items could not be marked; their paths are in the error's
    /// recovery suggestion.
    NAQuarantineErrorItemsNotMarked = 1,
};

/// Copies an archive's com.apple.quarantine extended attribute to the files
/// extracted from it, so Gatekeeper checks apps and executables taken out of a
/// downloaded archive before they first open.
@interface NAQuarantine : NSObject

/// Sets the quarantine value of sourceURL on the item at rootURL and on every item below
/// it. Symlinks receive the attribute themselves and are not followed; items
/// are opened relative to their parent directory with O_NOFOLLOW, so an item
/// replaced by a symlink during the walk is reported instead of followed. An item
/// without owner write permission is given it while the attribute is set, then
/// its mode is restored. A directory that cannot be listed is given owner rwx;
/// if it still cannot be listed it counts as an item that was not marked.
/// Returns YES when sourceURL has no quarantine value or every item received
/// it; otherwise NO with an error naming how many items were not marked.
+ (BOOL)copyQuarantineFromURL:(NSURL *)sourceURL
                  toTreeAtURL:(NSURL *)rootURL
                        error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
