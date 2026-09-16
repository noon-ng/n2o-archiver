#import <Foundation/Foundation.h>
#import "NAExtractorPlugin.h"

NS_ASSUME_NONNULL_BEGIN

/// Shared implementation for extractors that run 7zz. A subclass describes its
/// format with +signatures and +formatTypeForFileAtURL:. The format type is
/// passed to 7zz with -t, so a file routed by extension is opened only as that
/// format and 7zz does not detect another format from its content (for example
/// a disk image named .7z).
@interface NA7zzExtractor : NSObject <NAExtractorPlugin>

/// Leading bytes that identify the format; canHandleFileAtURL: matches any.
+ (NSArray<NSData *> *)signatures;

/// The 7zz -t value for the file at url, such as @"7z".
+ (NSString *)formatTypeForFileAtURL:(NSURL *)url;

/// The first length bytes of the file, or fewer if it is shorter; nil if it
/// cannot be read. For subclasses that choose a format type from the header.
+ (nullable NSData *)headerOfFileAtURL:(NSURL *)url length:(NSUInteger)length;

@end

NS_ASSUME_NONNULL_END
