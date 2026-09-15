#import "NA7zzExtractor.h"
#import "NA7zzTool.h"

@interface NA7zzExtractor ()
@property (atomic, assign) BOOL cancelled;
@end

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

+ (NSString *)formatTypeForFileAtPath:(NSString *)path {
    [NSException raise:NSInternalInconsistencyException
                format:@"%@ must override +formatTypeForFileAtPath:", self];
    return @"";
}

+ (nullable NSData *)headerOfFileAtPath:(NSString *)path length:(NSUInteger)length {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return nil;
    NSData *header = [fh readDataOfLength:length];
    [fh closeFile];
    return header;
}

+ (BOOL)canHandleFileAtPath:(NSString *)path {
    NSUInteger longest = 0;
    for (NSData *signature in [self signatures]) {
        longest = MAX(longest, signature.length);
    }
    NSData *header = [self headerOfFileAtPath:path length:longest];

    for (NSData *signature in [self signatures]) {
        if (header.length >= signature.length &&
            memcmp(header.bytes, signature.bytes, signature.length) == 0) {
            return YES;
        }
    }
    return NO;
}

- (BOOL)extractArchiveAtPath:(NSString *)archivePath
               toDestination:(NSString *)destPath
                    progress:(NAExtractionProgressBlock)progressBlock
                       error:(NSError **)error {
    return [NA7zzTool extractArchiveAtPath:archivePath
                                formatType:[[self class] formatTypeForFileAtPath:archivePath]
                             toDestination:destPath
                                  progress:progressBlock
                               isCancelled:^BOOL { return self.cancelled; }
                                     error:error];
}

- (void)cancelExtraction {
    self.cancelled = YES;
}

- (NSArray<NSString *> *)contentsOfArchiveAtPath:(NSString *)path
                                           error:(NSError **)error {
    return [NA7zzTool contentsOfArchiveAtPath:path
                                   formatType:[[self class] formatTypeForFileAtPath:path]
                                        error:error];
}

@end
