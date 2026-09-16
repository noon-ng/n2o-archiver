#import <Foundation/Foundation.h>
#import "NAExtractorPlugin.h"

NS_ASSUME_NONNULL_BEGIN

/// Parses the progress output of `7zz x -bsp1`. 7zz writes status strings
/// such as " 45% 3 - dir/file.txt" and overwrites them with runs of backspaces;
/// the handler receives the percentage as a fraction and the entry's path as
/// printed (relative to the destination).
/// appendData: may be called from any thread, with data split at any byte.
/// Errors from running 7zz. The code is the tool's exit status, except for
/// NA7zzErrorToolUnavailable.
extern NSErrorDomain const NA7zzErrorDomain;

typedef NS_ERROR_ENUM(NA7zzErrorDomain, NA7zzError) {
    /// No 7zz was found, or every candidate is older than the minimum version.
    NA7zzErrorToolUnavailable = -1,
};

@interface NA7zzProgressParser : NSObject

- (instancetype)initWithHandler:(void (^)(double fraction, NSString *entry))handler;
- (void)appendData:(NSData *)data;

@end

@interface NA7zzTool : NSObject

/// The first supported 7zz in candidatePaths, cached for the process; nil if
/// none is found or all are too old (see toolError).
+ (nullable NSString *)toolPath;

/// Why toolPath is nil, or nil if a supported 7zz was found.
+ (nullable NSError *)toolError;

/// Locations checked for 7zz, in order: Contents/Helpers/7zz in the app
/// bundle, then the Homebrew locations. Only binaries named 7zz are accepted;
/// a program named 7z may be p7zip, a separate and older code base.
+ (NSArray<NSString *> *)candidatePaths;

/// The first candidate that is executable and reports a supported version.
+ (nullable NSString *)toolPathFromCandidates:(NSArray<NSString *> *)candidates
                                        error:(NSError **)error;

/// The version printed on the first line of the tool's output, such as @"26.03".
+ (nullable NSString *)versionOfToolAtPath:(NSString *)path;

/// YES for "major.minor" versions at or above 25.01, the first release with
/// fixes for CVE-2025-11001, CVE-2025-11002 and CVE-2025-55188.
+ (BOOL)isSupportedVersion:(NSString *)version;

/// formatType is passed to 7zz as -t<formatType> (for example @"7z", @"rar",
/// @"rar5"), so the archive is opened only as that format. progress follows
/// the NAExtractorPlugin contract: its units are percent, and it is polled
/// for cancellation while 7zz runs; when cancelled the task is terminated and
/// the call returns NO with NSUserCancelledError.
+ (BOOL)extractArchiveAtPath:(NSString *)archivePath
                  formatType:(NSString *)formatType
               toDestination:(NSString *)destPath
                    progress:(NSProgress *)progress
                       error:(NSError **)error;

+ (nullable NSArray<NSString *> *)contentsOfArchiveAtPath:(NSString *)path
                                               formatType:(NSString *)formatType
                                                    error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
