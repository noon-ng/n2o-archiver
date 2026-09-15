#import "NA7zExtractor.h"

static const uint8_t k7zSignature[] = {'7', 'z', 0xBC, 0xAF, 0x27, 0x1C};

@implementation NA7zExtractor

+ (NSArray<NSString *> *)supportedExtensions {
    return @[@"7z"];
}

+ (NSArray<NSString *> *)supportedUTIs {
    return @[@"org.7-zip.7-zip-archive"];
}

+ (NSArray<NSData *> *)signatures {
    return @[[NSData dataWithBytes:k7zSignature length:sizeof(k7zSignature)]];
}

+ (NSString *)formatTypeForFileAtPath:(NSString *)path {
    return @"7z";
}

@end
