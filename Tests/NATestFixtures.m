#import "NATestFixtures.h"

static NSString *_fixtureDir;

@implementation NATestFixtures

+ (NSString *)fixtureDir {
    return _fixtureDir;
}

+ (NSString *)pathForFixture:(NSString *)name {
    return [_fixtureDir stringByAppendingPathComponent:name];
}

+ (void)setUp {
    _fixtureDir = [NSTemporaryDirectory()
        stringByAppendingPathComponent:
            [NSString stringWithFormat:@"n2o-archiver-tests-%u", arc4random()]];

    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:_fixtureDir
        withIntermediateDirectories:YES attributes:nil error:nil];

    // Create source files to archive.
    NSString *srcDir = [_fixtureDir stringByAppendingPathComponent:@"src"];
    [fm createDirectoryAtPath:srcDir
        withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *subDir = [srcDir stringByAppendingPathComponent:@"subdir"];
    [fm createDirectoryAtPath:subDir
        withIntermediateDirectories:YES attributes:nil error:nil];

    [@"file-a contents\n" writeToFile:[srcDir stringByAppendingPathComponent:@"a.txt"]
                           atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [@"file-b contents\n" writeToFile:[srcDir stringByAppendingPathComponent:@"b.txt"]
                           atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [@"nested contents\n" writeToFile:[subDir stringByAppendingPathComponent:@"c.txt"]
                           atomically:YES encoding:NSUTF8StringEncoding error:nil];

    // Generate archives using command-line tools.
    [self run:@"/usr/bin/tar" args:@[@"czf", [self pathForFixture:@"test.tar.gz"],
        @"-C", _fixtureDir, @"src"]];
    [self run:@"/usr/bin/tar" args:@[@"cjf", [self pathForFixture:@"test.tar.bz2"],
        @"-C", _fixtureDir, @"src"]];
    [self run:@"/usr/bin/tar" args:@[@"cf", [self pathForFixture:@"test.tar"],
        @"-C", _fixtureDir, @"src"]];

    // zip
    NSTask *zipTask = [[NSTask alloc] init];
    zipTask.launchPath = @"/usr/bin/zip";
    zipTask.arguments = @[@"-r", [self pathForFixture:@"test.zip"], @"src"];
    zipTask.currentDirectoryPath = _fixtureDir;
    zipTask.standardOutput = [NSPipe pipe];
    zipTask.standardError = [NSPipe pipe];
    [zipTask launch];
    [zipTask waitUntilExit];

    // tar.xz (requires xz, may not be available)
    if ([fm fileExistsAtPath:@"/opt/homebrew/bin/xz"] ||
        [fm fileExistsAtPath:@"/usr/bin/xz"]) {
        [self run:@"/usr/bin/tar" args:@[@"cJf", [self pathForFixture:@"test.tar.xz"],
            @"-C", _fixtureDir, @"src"]];
    }

    // cpio
    NSTask *cpioTask = [[NSTask alloc] init];
    cpioTask.launchPath = @"/bin/sh";
    cpioTask.arguments = @[@"-c",
        [NSString stringWithFormat:
            @"cd '%@' && find src -print | cpio -o > '%@'",
            _fixtureDir, [self pathForFixture:@"test.cpio"]]];
    cpioTask.standardOutput = [NSPipe pipe];
    cpioTask.standardError = [NSPipe pipe];
    [cpioTask launch];
    [cpioTask waitUntilExit];

    // Corrupt archive: random bytes.
    NSMutableData *junk = [NSMutableData dataWithLength:512];
    arc4random_buf(junk.mutableBytes, 512);
    [junk writeToFile:[self pathForFixture:@"corrupt.zip"] atomically:YES];

    // Multi-root archive (no single top-level directory).
    NSString *multiSrc = [_fixtureDir stringByAppendingPathComponent:@"multi"];
    [fm createDirectoryAtPath:multiSrc
        withIntermediateDirectories:YES attributes:nil error:nil];
    [@"root-1\n" writeToFile:[multiSrc stringByAppendingPathComponent:@"one.txt"]
                  atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [@"root-2\n" writeToFile:[multiSrc stringByAppendingPathComponent:@"two.txt"]
                  atomically:YES encoding:NSUTF8StringEncoding error:nil];

    NSTask *multiZip = [[NSTask alloc] init];
    multiZip.launchPath = @"/usr/bin/zip";
    multiZip.arguments = @[@"-r", [self pathForFixture:@"multi.zip"], @"one.txt", @"two.txt"];
    multiZip.currentDirectoryPath = multiSrc;
    multiZip.standardOutput = [NSPipe pipe];
    multiZip.standardError = [NSPipe pipe];
    [multiZip launch];
    [multiZip waitUntilExit];
}

+ (void)tearDown {
    if (_fixtureDir) {
        [[NSFileManager defaultManager] removeItemAtPath:_fixtureDir error:nil];
        _fixtureDir = nil;
    }
}

+ (void)run:(NSString *)path args:(NSArray<NSString *> *)args {
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = path;
    task.arguments = args;
    task.standardOutput = [NSPipe pipe];
    task.standardError = [NSPipe pipe];
    [task launch];
    [task waitUntilExit];
}

@end
