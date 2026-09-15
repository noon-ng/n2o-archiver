#import "NA7zExtractor.h"
#import "NA7zzTool.h"

static const uint8_t k7zSignature[] = {'7', 'z', 0xBC, 0xAF, 0x27, 0x1C};

@interface NA7zExtractor ()
@property (atomic, assign) BOOL cancelled;
@end

@implementation NA7zExtractor

+ (NSArray<NSString *> *)supportedExtensions {
    return @[@"7z"];
}

+ (NSArray<NSString *> *)supportedUTIs {
    return @[@"org.7-zip.7-zip-archive"];
}

+ (BOOL)canHandleFileAtPath:(NSString *)path {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return NO;

    NSData *header = [fh readDataOfLength:sizeof(k7zSignature)];
    [fh closeFile];

    if (header.length < sizeof(k7zSignature)) return NO;
    return memcmp(header.bytes, k7zSignature, sizeof(k7zSignature)) == 0;
}

- (BOOL)extractArchiveAtPath:(NSString *)archivePath
               toDestination:(NSString *)destPath
                    progress:(NAExtractionProgressBlock)progressBlock
                       error:(NSError **)error {
    return [NA7zzTool extractArchiveAtPath:archivePath
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
    return [NA7zzTool contentsOfArchiveAtPath:path error:error];
}

@end
