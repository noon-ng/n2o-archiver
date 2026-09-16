// Source of Tests/Fixtures/AdHocSignedPlugin.bundle, a plugin that conforms to
// NAExtractorPlugin and has a valid ad-hoc signature, not issued by Apple.
// Rebuild with Tests/PluginFixture/build.sh.
#import <Foundation/Foundation.h>
#import "NAExtractorPlugin.h"

@interface NATestAdHocPlugin : NSObject <NAExtractorPlugin>
@end

@implementation NATestAdHocPlugin

+ (NSArray<NSString *> *)supportedExtensions { return @[@"n2otest"]; }
+ (NSArray<NSString *> *)supportedUTIs { return @[]; }
+ (BOOL)canHandleFileAtURL:(NSURL *)url { return NO; }

- (BOOL)extractArchiveAtURL:(NSURL *)archiveURL
           toDestinationURL:(NSURL *)destinationURL
                   progress:(NSProgress *)progress
                      error:(NSError **)error {
    return NO;
}

@end
