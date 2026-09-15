#import "NARarExtractor.h"

static const uint8_t kRar4Signature[] = {'R', 'a', 'r', '!', 0x1A, 0x07, 0x00};
static const uint8_t kRar5Signature[] = {'R', 'a', 'r', '!', 0x1A, 0x07, 0x01, 0x00};

@implementation NARarExtractor

+ (NSArray<NSString *> *)supportedExtensions {
    return @[@"rar"];
}

+ (NSArray<NSString *> *)supportedUTIs {
    return @[@"com.rarlab.rar-archive"];
}

+ (NSArray<NSData *> *)signatures {
    return @[[NSData dataWithBytes:kRar5Signature length:sizeof(kRar5Signature)],
             [NSData dataWithBytes:kRar4Signature length:sizeof(kRar4Signature)]];
}

// 7zz has separate types for RAR5 and for RAR 1.5–4; a RAR4 archive does not
// open as rar5. A file without either signature is given "rar", which fails.
+ (NSString *)formatTypeForFileAtPath:(NSString *)path {
    NSData *header = [self headerOfFileAtPath:path length:sizeof(kRar5Signature)];
    BOOL rar5 = header.length == sizeof(kRar5Signature) &&
                memcmp(header.bytes, kRar5Signature, sizeof(kRar5Signature)) == 0;
    return rar5 ? @"rar5" : @"rar";
}

@end
