#import "NARarExtractor.h"
#import "NA7zzTool.h"

static const uint8_t kRar4Signature[] = {'R', 'a', 'r', '!', 0x1A, 0x07, 0x00};
static const uint8_t kRar5Signature[] = {'R', 'a', 'r', '!', 0x1A, 0x07, 0x01, 0x00};

@implementation NARarExtractor

+ (NSArray<NSString *> *)supportedExtensions {
    return @[@"rar", @"r00"];
}

+ (NSArray<NSString *> *)supportedUTIs {
    return @[@"com.rarlab.rar-archive"];
}

+ (BOOL)canHandleFileAtPath:(NSString *)path {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return NO;

    NSData *header = [fh readDataOfLength:sizeof(kRar5Signature)];
    [fh closeFile];

    if (header.length < sizeof(kRar4Signature)) return NO;

    if (memcmp(header.bytes, kRar5Signature, sizeof(kRar5Signature)) == 0) return YES;
    if (memcmp(header.bytes, kRar4Signature, sizeof(kRar4Signature)) == 0) return YES;
    return NO;
}

- (BOOL)extractArchiveAtPath:(NSString *)archivePath
               toDestination:(NSString *)destPath
                    progress:(NAExtractionProgressBlock)progressBlock
                       error:(NSError **)error {
    return [NA7zzTool extractArchiveAtPath:archivePath
                             toDestination:destPath
                                  progress:progressBlock
                                     error:error];
}

- (NSArray<NSString *> *)contentsOfArchiveAtPath:(NSString *)path
                                           error:(NSError **)error {
    return [NA7zzTool contentsOfArchiveAtPath:path error:error];
}

@end
