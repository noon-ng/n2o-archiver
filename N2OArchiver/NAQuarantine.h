#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const NAQuarantineErrorDomain;

/// Copies an archive's com.apple.quarantine extended attribute to the files
/// extracted from it, so Gatekeeper checks apps and executables taken out of a
/// downloaded archive before they first open.
@interface NAQuarantine : NSObject

/// Sets the quarantine value of sourcePath on rootPath and on every item below
/// it. Symlinks receive the attribute themselves and are not followed. An item
/// without owner write permission is given it while the attribute is set, then
/// its mode is restored. A directory that cannot be listed is given owner rwx;
/// if it still cannot be listed it counts as an item that was not marked.
/// Returns YES when sourcePath has no quarantine value or every item received
/// it; otherwise NO with an error naming how many items were not marked.
+ (BOOL)copyQuarantineFromPath:(NSString *)sourcePath
                  toTreeAtPath:(NSString *)rootPath
                         error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
