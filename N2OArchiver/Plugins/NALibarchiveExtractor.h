#import <Foundation/Foundation.h>
#import "NAExtractorPlugin.h"

/// Errors from libarchive itself and from this extractor's own checks.
extern NSErrorDomain const NALibarchiveErrorDomain;

typedef NS_ERROR_ENUM(NALibarchiveErrorDomain, NALibarchiveError) {
    /// The archive could not be opened.
    NALibarchiveErrorOpen = 1,
    /// An entry's data could not be read or written.
    NALibarchiveErrorData = 2,
    /// An entry could not be created, including entries rejected by the
    /// SECURE_NODOTDOT and SECURE_SYMLINKS checks.
    NALibarchiveErrorWriteEntry = 3,
    /// The file is not an archive in a supported format.
    NALibarchiveErrorUnrecognizedFormat = 4,
    /// An entry header could not be read, so the rest of the archive is lost.
    NALibarchiveErrorReadHeader = 5,
    /// An entry has no readable name.
    NALibarchiveErrorEntryName = 6,
    /// The archive holds no entries.
    NALibarchiveErrorNoEntries = 7,
};

@interface NALibarchiveExtractor : NSObject <NAExtractorPlugin>
@end
