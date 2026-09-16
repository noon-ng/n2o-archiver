#import "NA7zzExtractor.h"
#import "NA7zzTool.h"

@implementation NA7zzExtractor

+ (NSArray<NSString *> *)supportedExtensions {
    return @[];
}

+ (NSArray<NSString *> *)supportedUTIs {
    return @[];
}

+ (NSArray<NSData *> *)signatures {
    return @[];
}

+ (NSString *)formatTypeForFileAtURL:(NSURL *)url {
    [NSException raise:NSInternalInconsistencyException
                format:@"%@ must override +formatTypeForFileAtURL:", self];
    return @"";
}

+ (nullable NSData *)headerOfFileAtURL:(NSURL *)url length:(NSUInteger)length {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingFromURL:url error:nil];
    if (!fh) return nil;
    NSData *header = [fh readDataOfLength:length];
    [fh closeFile];
    return header;
}

+ (BOOL)canHandleFileAtURL:(NSURL *)url {
    NSUInteger longest = 0;
    for (NSData *signature in [self signatures]) {
        longest = MAX(longest, signature.length);
    }
    NSData *header = [self headerOfFileAtURL:url length:longest];

    for (NSData *signature in [self signatures]) {
        if (header.length >= signature.length &&
            memcmp(header.bytes, signature.bytes, signature.length) == 0) {
            return YES;
        }
    }
    return NO;
}

- (BOOL)extractArchiveAtURL:(NSURL *)archiveURL
           toDestinationURL:(NSURL *)destinationURL
                   progress:(NSProgress *)progress
                      error:(NSError **)error {
    return [NA7zzTool extractArchiveAtURL:archiveURL
                               formatType:[[self class] formatTypeForFileAtURL:archiveURL]
                         toDestinationURL:destinationURL
                                 progress:progress
                                    error:error];
}

- (NSArray<NSString *> *)contentsOfArchiveAtURL:(NSURL *)url
                                          error:(NSError **)error {
    return [NA7zzTool contentsOfArchiveAtURL:url
                                  formatType:[[self class] formatTypeForFileAtURL:url]
                                       error:error];
}

@end
