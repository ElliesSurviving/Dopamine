//
//  EnvironmentManager.m
//  Dopamine
//
//  Created by Lars Fröder on 10.01.24.
//

#import "DOEnvironmentManager.h"

#import <sys/sysctl.h>
#import <mach-o/dyld.h>
#import <libgrabkernel2/libgrabkernel2.h>
#import <libjailbreak/info.h>
#import <libjailbreak/codesign.h>
#import <libjailbreak/util.h>
#import <libjailbreak/machine_info.h>
#import <libjailbreak/carboncopy.h>

#import <IOKit/IOKitLib.h>
#import "DOUIManager.h"
#import "DOExploitManager.h"
#import "NSData+Hex.h"
#import "NSString+Version.h"

int reboot3(uint64_t flags, ...);

@implementation DOEnvironmentManager

@synthesize bootManifestHash = _bootManifestHash;

+ (instancetype)sharedManager
{
    static DOEnvironmentManager *shared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[DOEnvironmentManager alloc] init];
    });
    return shared;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _bootstrapNeedsMigration = NO;
        _bootstrapper = [[DOBootstrapper alloc] init];
        if ([self isJailbroken]) {
            gSystemInfo.jailbreakInfo.rootPath = strdup(jbclient_get_jbroot() ?: "");
        }
        else if ([self isInstalledThroughTrollStore]) {
            [self locateJailbreakRoot];
        }
    }
    return self;
}

- (NSString *)nightlyHash
{
#ifdef NIGHTLY
    return [NSString stringWithUTF8String:COMMIT_HASH];
#else
    return nil;
#endif
}

- (NSString *)appVersion
{
    return [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
}

- (NSString *)appVersionDisplayString
{
    NSString *nightlyHash = [self nightlyHash];
    if (nightlyHash) {
        return [NSString stringWithFormat:@"%@~%@", self.appVersion, [nightlyHash substringToIndex:6]];
    }
    else {
        return [self appVersion];
    }
}

- (NSData *)bootManifestHash
{
    if (!_bootManifestHash) {
        io_registry_entry_t registryEntry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/chosen");
        if (registryEntry) {
            _bootManifestHash = (__bridge NSData *)IORegistryEntryCreateCFProperty(registryEntry, CFSTR("boot-manifest-hash"), NULL, 0);
        }
    }
    return _bootManifestHash;
}

- (NSString *)activePrebootPath
{
    return [@"/private/preboot" stringByAppendingPathComponent:[self bootManifestHash].hexString];
}

- (void)locateJailbreakRoot
{
    if (!gSystemInfo.jailbreakInfo.rootPath) {
        NSString *activePrebootPath = [self activePrebootPath];
        
        NSString *randomizedJailbreakPath;
        
        // First attempt at finding jailbreak root, look for Dopamine 2.x path
        for (NSString *subItem in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:activePrebootPath error:nil]) {
            if (subItem.length == 15 && [subItem hasPrefix:@"dopamine-"]) {
                randomizedJailbreakPath = [activePrebootPath stringByAppendingPathComponent:subItem];
                BOOL installedWinters = [[NSFileManager defaultManager] fileExistsAtPath:[randomizedJailbreakPath stringByAppendingPathComponent:@"procursus/.installed_winters"]];
                if (!installedWinters) {
                     _bootstrapNeedsMigration = YES;
                }
                else {
                break;
                }
            }
        }
        
        if (!randomizedJailbreakPath) {
            // Second attempt at finding jailbreak root, look for Dopamine 1.x path, but as other jailbreaks use it too, make sure it is Dopamine
            // Some other jailbreaks also commit the sin of creating .installed_dopamine, for these we try to filter them out by checking for their installed_ file
            // If we find this and are sure it's from Dopamine 1.x, rename it so all Dopamine 2.x users will have the same path
            for (NSString *subItem in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:activePrebootPath error:nil]) {
                if (subItem.length == 9 && [subItem hasPrefix:@"jb-"]) {
                    NSString *candidateLegacyPath = [activePrebootPath stringByAppendingPathComponent:subItem];
                    
                    BOOL installedDopamine = [[NSFileManager defaultManager] fileExistsAtPath:[candidateLegacyPath stringByAppendingPathComponent:@"procursus/.installed_winters"]];
                    
                    if (installedDopamine) {
                        // Hopefully all other jailbreaks that use jb-<UUID>?
                        // These checks exist because of dumb users (and jailbreak developers) creating .installed_dopamine on jailbreaks that are NOT dopamine...
                        BOOL installedNekoJB = [[NSFileManager defaultManager] fileExistsAtPath:[candidateLegacyPath stringByAppendingPathComponent:@"procursus/.installed_nekojb"]];
                        BOOL installedDefinitelyNotAGoodName = [[NSFileManager defaultManager] fileExistsAtPath:[candidateLegacyPath stringByAppendingPathComponent:@"procursus/.xia0o0o0o_jb_installed"]];
                        if (installedNekoJB || installedDefinitelyNotAGoodName) {
                            continue;
                        }
                        
                        randomizedJailbreakPath = candidateLegacyPath;
                        _bootstrapNeedsMigration = YES;
                        break;
                    }
                }
            }
        }
        
        if (randomizedJailbreakPath) {
            NSString *jailbreakRootPath = [randomizedJailbreakPath stringByAppendingPathComponent:@"procursus"];
            if ([[NSFileManager defaultManager] fileExistsAtPath:jailbreakRootPath]) {
                // This attribute serves as the primary source of what the root path is
                // Anything else in the jailbreak will get it from here
                gSystemInfo.jailbreakInfo.rootPath = strdup(jailbreakRootPath.fileSystemRepresentation);
            }
        }
    }
}

- (NSError *)ensureJailbreakRootExists
{
    NSError *error=nil;
    [self locateJailbreakRoot];
    
    if (!gSystemInfo.jailbreakInfo.rootPath || _bootstrapNeedsMigration) {
        [_bootstrapper ensurePrivatePrebootIsWritable];

        NSString *activePrebootPath = [self activePrebootPath];

        NSString *characterSet = @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
        NSUInteger stringLen = 6;
        NSUInteger stringLenSecond = 8;
        NSMutableString *randomString = [NSMutableString stringWithCapacity:stringLen];
        NSMutableString *randomStringSecond = [NSMutableString stringWithCapacity:stringLenSecond];
        for (NSUInteger i = 0; i < stringLen; i++) {
            NSUInteger randomIndex = arc4random_uniform((uint32_t)[characterSet length]);
            unichar randomCharacter = [characterSet characterAtIndex:randomIndex];
            [randomString appendFormat:@"%C", randomCharacter];
        }
        for (NSUInteger i = 0; i < stringLenSecond; i++) {
            NSUInteger randomIndex = arc4random_uniform((uint32_t)[characterSet length]);
            unichar randomCharacter = [characterSet characterAtIndex:randomIndex];
            [randomStringSecond appendFormat:@"%C", randomCharacter];
        }

        BOOL x1linksEnabled = [[DOPreferenceManager sharedManager] boolPreferenceValueForKey:@"x1linksEnabled" fallback:NO];
        NSString *randomJailbreakFolderName = [NSString stringWithFormat:@"dopamine-%@", randomString];
        NSString *randomJailbreakFolderNameSecond = [NSString stringWithFormat:@"jb-%@", randomStringSecond];
        NSString *randomizedJailbreakPath = [activePrebootPath stringByAppendingPathComponent:randomJailbreakFolderName];
        NSString *randomizedJailbreakPathSecond = [activePrebootPath stringByAppendingPathComponent:randomJailbreakFolderNameSecond];
        NSString *secondJBPath = [randomizedJailbreakPathSecond stringByAppendingPathComponent:@"procursus"];
        NSString *jailbreakRootPath = [randomizedJailbreakPath stringByAppendingPathComponent:@"procursus"];
        NSString *procursusSymlinkLol = [activePrebootPath stringByAppendingPathComponent:@"procursus"];
        NSString *jailbreakRootCores = [jailbreakRootPath stringByAppendingPathComponent:@"cores"];
        NSString *jailbreakRootDeveloper = [jailbreakRootPath stringByAppendingPathComponent:@"Developer"];
        NSString *jailbreakRootPrivate = [jailbreakRootPath stringByAppendingPathComponent:@"private"];
        NSString *jailbreakRootSystemData = [jailbreakRootPrivate stringByAppendingPathComponent:@"system_data"];
        NSString *jailbreakRootEtc = [jailbreakRootPrivate stringByAppendingPathComponent:@"etc"];
        NSString *jailbreakRootmb = [jailbreakRootPath stringByAppendingPathComponent:@".mb"];
        NSString *jailbreakRootFseventsd = [jailbreakRootPath stringByAppendingPathComponent:@".fseventsd"];
        NSString *jailbreakRootba = [jailbreakRootPath stringByAppendingPathComponent:@".ba"];
        
        if (_bootstrapNeedsMigration) {
            NSString *oldRandomizedJailbreakPath = [[NSString stringWithUTF8String:gSystemInfo.jailbreakInfo.rootPath] stringByDeletingLastPathComponent];
            [[NSFileManager defaultManager] moveItemAtPath:oldRandomizedJailbreakPath toPath:randomizedJailbreakPath error:&error];
        }
        else {
            if (![[NSFileManager defaultManager] fileExistsAtPath:jailbreakRootPath]) {
                [[NSFileManager defaultManager] createDirectoryAtPath:jailbreakRootPath withIntermediateDirectories:YES attributes:nil error:&error];
                [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/jb" withDestinationPath:jailbreakRootPath error:&error];
                [[NSFileManager defaultManager] createDirectoryAtPath:randomizedJailbreakPathSecond withIntermediateDirectories:YES attributes:nil error:&error];
                [[NSFileManager defaultManager] createDirectoryAtPath:jailbreakRootCores withIntermediateDirectories:YES attributes:nil error:&error];
                [[NSFileManager defaultManager] createDirectoryAtPath:jailbreakRootDeveloper withIntermediateDirectories:YES attributes:nil error:&error];
                [[NSFileManager defaultManager] createDirectoryAtPath:jailbreakRootPrivate withIntermediateDirectories:YES attributes:nil error:&error];
                [[NSFileManager defaultManager] createDirectoryAtPath:jailbreakRootSystemData withIntermediateDirectories:YES attributes:nil error:&error];
                [[NSFileManager defaultManager] createDirectoryAtPath:jailbreakRootEtc withIntermediateDirectories:YES attributes:nil error:&error];
                [[NSFileManager defaultManager] createDirectoryAtPath:jailbreakRootEtc withIntermediateDirectories:YES attributes:nil error:&error];
                [[NSFileManager defaultManager] createDirectoryAtPath:jailbreakRootmb withIntermediateDirectories:YES attributes:nil error:&error];
                [[NSFileManager defaultManager] createDirectoryAtPath:jailbreakRootba withIntermediateDirectories:YES attributes:nil error:&error];
                [[NSFileManager defaultManager] createDirectoryAtPath:jailbreakRootFseventsd withIntermediateDirectories:YES attributes:nil error:&error];
                [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/jb/System" withIntermediateDirectories:YES attributes:nil error:&error];
                [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/jb/System/DriverKit" withIntermediateDirectories:YES attributes:nil error:&error];
                [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/jb/System/Developer" withIntermediateDirectories:YES attributes:nil error:&error];
                [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/jb/etc" withDestinationPath:@"/var/jb/private/etc" error:&error];
                [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/jb/var" withDestinationPath:@"/var" error:&error];
                [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/jb/private/var" withDestinationPath:@"/var" error:&error];
                [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/jb/private/preboot" withDestinationPath:@"/private/preboot" error:&error];
                [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/jb/private/xarts" withDestinationPath:@"/private/xarts" error:&error];
                [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/jb/dev" withDestinationPath:@"/dev" error:&error];
                [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/jb/tmp" withDestinationPath:@"/var/tmp" error:&error];
                [[NSFileManager defaultManager] createSymbolicLinkAtPath:secondJBPath withDestinationPath:jailbreakRootPath error:&error];
                [[NSFileManager defaultManager] createSymbolicLinkAtPath:procursusSymlinkLol withDestinationPath:jailbreakRootPath error:&error];
                [[NSData data] writeToFile:@"/var/jb/.fseventsd/fseventsd-uuid" atomically:YES];
                if (@available(iOS 16.0, *)) {
                    [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/jb/System/Applications" withIntermediateDirectories:YES attributes:nil error:&error];
                    [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/jb/System/Cryptexes" withIntermediateDirectories:YES attributes:nil error:&error];
                    [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/jb/System/Cryptexes/App" withDestinationPath:@"/System/Cryptexes/App" error:&error];
                    [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/jb/System/Cryptexes/OS" withDestinationPath:@"/System/Cryptexes/OS" error:&error];
                    
                }
                if (x1linksEnabled) {
                    [[NSFileManager defaultManager] removeItemAtPath:@"/var/ap" error:nil];
                    [[NSFileManager defaultManager] removeItemAtPath:@"/var/apt" error:nil];
                    [[NSFileManager defaultManager] removeItemAtPath:@"/var/lib" error:nil];
                    [[NSFileManager defaultManager] removeItemAtPath:@"/var/alternatives" error:nil];
                    [[NSFileManager defaultManager] removeItemAtPath:@"/var/bash" error:nil];
                    [[NSFileManager defaultManager] removeItemAtPath:@"/var/zsh" error:nil];
                    [[NSFileManager defaultManager] removeItemAtPath:@"/var/.keep_symlinks" error:nil];
                    [[NSFileManager defaultManager] removeItemAtPath:@"/var/zlogin" error:nil];
                    [[NSFileManager defaultManager] removeItemAtPath:@"/var/zlogout" error:nil];
                    [[NSFileManager defaultManager] removeItemAtPath:@"/var/zprofile" error:nil];
                    [[NSFileManager defaultManager] removeItemAtPath:@"/var/zshenv" error:nil];
                    [[NSFileManager defaultManager] removeItemAtPath:@"/var/zshrc" error:nil];
                    [[NSFileManager defaultManager] removeItemAtPath:@"/var/bin" error:nil];
                    [[NSFileManager defaultManager] removeItemAtPath:@"/var/bzip2" error:nil];
                    [[NSFileManager defaultManager] removeItemAtPath:@"/var/cache" error:nil];
                    [[NSFileManager defaultManager] removeItemAtPath:@"/var/dpkg" error:nil];
                    [[NSFileManager defaultManager] removeItemAtPath:@"/var/etc" error:nil];
                    [[NSFileManager defaultManager] removeItemAtPath:@"/var/gzip" error:nil];
                    [[NSFileManager defaultManager] removeItemAtPath:@"/var/Lib" error:nil];
                    [[NSFileManager defaultManager] removeItemAtPath:@"/var/libexec" error:nil];
                    [[NSFileManager defaultManager] removeItemAtPath:@"/var/Library" error:nil];
                    [[NSFileManager defaultManager] removeItemAtPath:@"/var/LIY" error:nil];
                    [[NSFileManager defaultManager] removeItemAtPath:@"/var/Liy" error:nil];
                    [[NSFileManager defaultManager] removeItemAtPath:@"/var/LIy" error:nil];
                    [[NSFileManager defaultManager] removeItemAtPath:@"/var/local" error:nil];
                    [[NSFileManager defaultManager] removeItemAtPath:@"/var/newuser" error:nil];
                    [[NSFileManager defaultManager] removeItemAtPath:@"/var/profile" error:nil];
                    [[NSFileManager defaultManager] removeItemAtPath:@"/var/sbin" error:nil];
                    [[NSFileManager defaultManager] removeItemAtPath:@"/var/suid_profile" error:nil];
                    [[NSFileManager defaultManager] removeItemAtPath:@"/var/sy" error:nil];
                    [[NSFileManager defaultManager] removeItemAtPath:@"/var/usr" error:nil];
                    [[NSFileManager defaultManager] removeItemAtPath:@"/var/sh" error:nil];
                    [[NSFileManager defaultManager] removeItemAtPath:@"/var/share" error:nil];
                    [[NSFileManager defaultManager] removeItemAtPath:@"/var/ssh" error:nil];
                    [[NSFileManager defaultManager] removeItemAtPath:@"/var/sudo_logsrvd.conf" error:nil];
                    [[NSFileManager defaultManager] removeItemAtPath:@"/var/master.passwd" error:nil];
                    [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/jb/usr" withIntermediateDirectories:YES attributes:nil error:&error];
                    [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/jb/Library" withIntermediateDirectories:YES attributes:nil error:&error];
                    [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/jb/Library/Themes" withIntermediateDirectories:YES attributes:nil error:&error];
                    [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/jb/usr/lib" withIntermediateDirectories:YES attributes:nil error:&error];
                    [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/jb/usr/local" withIntermediateDirectories:YES attributes:nil error:&error];
                    [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/jb/usr/cache" withIntermediateDirectories:YES attributes:nil error:&error];
                    [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/jb/Xapps" withDestinationPath:@"/var/jb/Applications" error:&error];
                    [[NSData data] writeToFile:@"/var/jb/xina118" atomically:YES];
                    [[NSData data] writeToFile:@"/var/jb/.x1links" atomically:YES];
                    [[NSData data] writeToFile:@"/var/.keep_symlinks" atomically:YES];
                    if (![[NSFileManager defaultManager] fileExistsAtPath:@"/var/mobile/.zprofile"]) {
                        [[NSData data] writeToFile:@"/var/mobile/.zlogin" atomically:YES];
                        [[NSData data] writeToFile:@"/var/mobile/.zlogout" atomically:YES];
                        [[NSData data] writeToFile:@"/var/mobile/.zprofile" atomically:YES];
                        [[NSData data] writeToFile:@"/var/mobile/.zshenv" atomically:YES];
                        [[NSData data] writeToFile:@"/var/mobile/.zshrc" atomically:YES];
                    }
                    [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/lib" withDestinationPath:@"/var/jb/usr/lib" error:&error];
                    [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/alternatives" withDestinationPath:@"/var/jb/etc/alternatives" error:&error];
                    [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/ap" withDestinationPath:@"/var/jb/etc/apt" error:&error];
                    [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/apt" withDestinationPath:@"/var/jb/etc/apt" error:&error];
                    [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/zsh" withDestinationPath:@"/var/jb/bin/zsh" error:&error];
                    [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/bin" withDestinationPath:@"/var/jb/usr/bin" error:&error];
                    [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/bash" withDestinationPath:@"/var/jb/bin/bash" error:&error];
                    [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/bzip2" withDestinationPath:@"/var/jb/usr/bin/bzip2" error:&error];
                    [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/dpkg" withDestinationPath:@"/var/jb/etc/dpkg" error:&error];
                    [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/cache" withDestinationPath:@"/var/jb/usr/cache" error:&error];
                    [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/etc" withDestinationPath:@"/var/jb/etc" error:&error];
                    [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/local" withDestinationPath:@"/var/jb/usr/local" error:&error];
                    [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/gzip" withDestinationPath:@"/var/jb/bin/gzip" error:&error];
                    [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/LIB" withDestinationPath:@"/var/jb/Library" error:&error];
                    [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/sy" withDestinationPath:@"/var/jb/System" error:&error];
                    [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/lib/dpkg" withDestinationPath:@"/var/jb/Library/dpkg" error:&error];
                    [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/Lib" withDestinationPath:@"/var/jb/usr/lib" error:&error];
                    [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/libexec" withDestinationPath:@"/var/jb/usr/libexec" error:&error];
                    [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/Library" withDestinationPath:@"/var/jb/Library" error:&error];
                    [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/Liy" withDestinationPath:@"/var/jb/Library" error:&error];
                    [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/LIy" withDestinationPath:@"/var/jb/Library" error:&error];
                    [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/LIY" withDestinationPath:@"/var/jb/Library" error:&error];
                    [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/master.passwd" withDestinationPath:@"/var/jb/etc/master.passwd" error:&error];
                    [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/newuser" withDestinationPath:@"/var/jb/usr/sbin/adduser" error:&error];
                    [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/profile" withDestinationPath:@"/var/jb/etc/profile" error:&error];
                    [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/sbin" withDestinationPath:@"/var/jb/usr/sbin" error:&error];
                    [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/ssh" withDestinationPath:@"/var/jb/etc/ssh" error:&error];
                    [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/sudo_logsrvd.conf" withDestinationPath:@"/var/jb/etc/sudo_logsrvd.conf" error:&error];
                    [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/Themes" withDestinationPath:@"/var/jb/Library/Themes" error:&error];
                    [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/ubi" withDestinationPath:@"/var/jb/usr/bin" error:&error];
                    [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/ulb" withDestinationPath:@"/var/jb/usr/lib" error:&error];
                    [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/zshrc" withDestinationPath:@"/var/mobile/.zshrc" error:&error];
                    [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/zprofile" withDestinationPath:@"/var/mobile/.zprofile" error:&error];
                    [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/zshenv" withDestinationPath:@"/var/mobile/.zshenv" error:&error];
                    [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/zlogin" withDestinationPath:@"/var/mobile/.zlogin" error:&error];
                    [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/zlogout" withDestinationPath:@"/var/mobile/.zlogout" error:&error];
                    [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var//jb/UsrLb" withDestinationPath:@"/var/mobile/Library" error:&error];
                    [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/jb/vmo" withDestinationPath:@"/var/mobile" error:&error];
                    [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/share" withDestinationPath:@"/var/jb/usr/share" error:&error];
                    [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/sh" withDestinationPath:@"/var/jb/bin/sh" error:&error];
                    [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/usr" withDestinationPath:@"/var/jb/usr" error:&error];


                }

            }
        }
        
        if (!error) {
            gSystemInfo.jailbreakInfo.rootPath = strdup(jailbreakRootPath.UTF8String);
        }
    }
    return error;
}

- (BOOL)isArm64e
{
    cpu_subtype_t cpusubtype = 0;
    size_t len = sizeof(cpusubtype);
    if (sysctlbyname("hw.cpusubtype", &cpusubtype, &len, NULL, 0) == -1) { return NO; }
    return (cpusubtype & ~CPU_SUBTYPE_MASK) == CPU_SUBTYPE_ARM64E;
}

- (NSString *)versionSupportString
{
    if ([self isArm64e]) {
        return @"iOS 15.0 - 16.5.1 (arm64e), v2.2.2-Nightly.3-fix1";
    }
    else {
        return @"iOS 15.0 - 16.6.1 (arm64), v2.2.2-Nightly.3-fix1";
    }
}

- (BOOL)isInstalledThroughTrollStore
{
    static BOOL trollstoreInstallation = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString* trollStoreMarkerPath = [[[NSBundle mainBundle].bundlePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"_TrollStore"];
        trollstoreInstallation = [[NSFileManager defaultManager] fileExistsAtPath:trollStoreMarkerPath];
    });
    return trollstoreInstallation;
}

- (BOOL)isJailbroken
{
    static BOOL jailbroken = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        uint32_t csFlags = 0;
        csops(getpid(), CS_OPS_STATUS, &csFlags, sizeof(csFlags));
        jailbroken = csFlags & CS_PLATFORM_BINARY;
    });
    return jailbroken;
}

- (NSString *)jailbrokenVersion
{
    if (!self.isJailbroken) return nil;

    __block NSString *version;
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            version = [NSString stringWithContentsOfFile:JBROOT_PATH(@"/basebin/.version") encoding:NSUTF8StringEncoding error:nil];
        }];
    }];
    return version;
}

- (BOOL)isBootstrapped
{
    return (BOOL)jbinfo(rootPath);
}

- (void)runUnsandboxed:(void (^)(void))unsandboxBlock
{
    if ([self isInstalledThroughTrollStore]) {
        unsandboxBlock();
    }
    else if([self isJailbroken]) {
        uint64_t labelBackup = 0;
        jbclient_root_set_mac_label(1, -1, &labelBackup);
        unsandboxBlock();
        jbclient_root_set_mac_label(1, labelBackup, NULL);
    }
    else {
        // Hope that we are already unsandboxed
        unsandboxBlock();
    }
}

- (void)runAsRoot:(void (^)(void))rootBlock
{
    uint32_t orgUser = getuid();
    uint32_t orgGroup = getgid();
    if (geteuid() == 0 && orgGroup == 0) {
        rootBlock();
        return;
    }

    int ur = 0, gr = 0;
    if (orgUser != 0) ur = setuid(0);
    if (orgGroup != 0) gr = setgid(0);
    if (ur == 0 && gr == 0) {
        rootBlock();
    }
    
    if (gr == 0 && orgGroup != 0) setgid(orgGroup);
    if (ur == 0 && orgUser != 0) seteuid(orgUser);
}

- (int)runTrollStoreAction:(NSString *)action
{
    if (![self isInstalledThroughTrollStore]) return -1;
    
    uint32_t selfPathSize = PATH_MAX;
    char selfPath[selfPathSize];
    _NSGetExecutablePath(selfPath, &selfPathSize);
    return exec_cmd_root(selfPath, "trollstore", action.UTF8String, NULL);
}

- (void)respring
{
    [self runAsRoot:^{
        __block int pid = 0;
        __block int r = 0;
        [self runUnsandboxed:^{
            r = exec_cmd_suspended(&pid, JBROOT_PATH("/usr/bin/sbreload"), NULL);
            if (r == 0) {
                kill(pid, SIGCONT);
            }
        }];
        if (r == 0) {
            cmd_wait_for_exit(pid);
        }
    }];
}

- (void)rebootUserspace
{
    [self runAsRoot:^{
        __block int pid = 0;
        __block int r = 0;
        [self runUnsandboxed:^{
            r = exec_cmd_suspended(&pid, JBROOT_PATH("/basebin/jailbreakd"), "reboot_userspace", NULL);
            if (r == 0) {
                // the original plan was to have the process continue outside of this block
                // unfortunately sandbox blocks kill aswell, so it's a bit racy but works

                // we assume we leave this unsandbox block before the userspace reboot starts
                // to avoid leaking the label, this seems to work in practice
                // and even if it doesn't work, leaking the label is no big deal
                kill(pid, SIGCONT);
            }
        }];
        if (r == 0) {
            cmd_wait_for_exit(pid);
        }
    }];
}

- (void)refreshJailbreakApps
{
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            exec_cmd(JBROOT_PATH("/usr/bin/uicache"), "-a", NULL);
        }];
    }];
}

- (void)allactionscall
{
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            exec_cmd("/sbin/mount", "-uw", "/private/preboot", NULL);
            exec_cmd("/var/jb/bin/launchctl", "bootstrap", "system", "/var/jb/Library/LaunchDaemons", NULL);
            exec_cmd("/var/jb/usr/libexec/ellekit/loader", NULL);
            exec_cmd("uicache", "-a", NULL);
            exec_cmd("/var/jb/usr/bin/sbreload", NULL);
        }];
    }];
}

- (void)seppaniccall
{
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            exec_cmd("/usr/libexec/seputil", "--sepospanic", NULL);
        }];
    }];
}

- (void)ldrestartcall
{
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            exec_cmd("/var/jb/bin/launchctl", "reboot", "userspace", NULL);
        }];
    }];
}

- (void)forcetweakscall
{
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            exec_cmd("/var/jb/usr/libexec/ellekit/loader", NULL);
        }];
    }];
}

- (void)appstorefixcall
{
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            exec_cmd("/var/jb/usr/bin/chown", "root:wheel", "/var/tmp", NULL);
            exec_cmd("/var/jb/usr/bin/chown", "mobile:wheel", "/var/tmp/com.apple.appstored", NULL);
            exec_cmd("/var/jb/usr/bin/chmod", "777", "/var/tmp", NULL);
            exec_cmd("/var/jb/usr/bin/chmod", "700", "/var/tmp/com.apple.appstored", NULL);
            exec_cmd("/var/jb/usr/bin/killall", "-9", "appstored", NULL);

        }];
    }];
}

- (void)launchstuffcall
{
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            exec_cmd("/var/jb/bin/launchctl", "bootstrap", "system", "/var/jb/Library/LaunchDaemons", NULL);
        }];
    }];
}

- (void)remountdirscall
{
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            exec_cmd("/sbin/mount", "-uw", "/private/preboot", NULL);
        }];
    }];
}

- (void)killallspringboard
{
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            exec_cmd("/var/jb/usr/bin/killall", "SpringBoard", NULL);
        }];
    }];
}

- (void)killallDopamineApp
{
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            exec_cmd("/var/jb/usr/bin/killall", "Dopamine", NULL);
        }];
    }];
}

- (void)unregisterJailbreakApps
{
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            NSArray *jailbreakApps = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:JBROOT_PATH(@"/Applications") error:nil];
            if (jailbreakApps.count) {
                for (NSString *jailbreakApp in jailbreakApps) {
                    NSString *jailbreakAppPath = [JBROOT_PATH(@"/Applications") stringByAppendingPathComponent:jailbreakApp];
                    exec_cmd(JBROOT_PATH("/usr/bin/uicache"), "-u", jailbreakAppPath.fileSystemRepresentation, NULL);
                }
            }
        }];
    }];
}

- (void)reboot
{
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            reboot3(0x8000000000000000, 0);
        }];
    }];
}


- (NSError*)updateEnvironment
{
    NSString *newBasebinTarPath = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"basebin.tar"];
    int result = jbclient_platform_stage_jailbreak_update(newBasebinTarPath.fileSystemRepresentation);
    if (result == 0) {
        [self ldrestartcall];
        return nil;
    }
    return [NSError errorWithDomain:@"Dopamine" code:result userInfo:nil];
}

- (void)updateJailbreakFromTIPA:(NSString *)tipaPath
{
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            pid_t pid = 0;
            if (exec_cmd_suspended(&pid, JBROOT_PATH("/basebin/jailbreakd"), "update", "tipa", tipaPath.fileSystemRepresentation, NULL) == 0) {
                kill(pid, SIGCONT);
            }
        }];
    }];
}

- (BOOL)isTweakInjectionEnabled
{
    return ![[NSFileManager defaultManager] fileExistsAtPath:JBROOT_PATH(@"/basebin/.safe_mode")];
}

- (void)setTweakInjectionEnabled:(BOOL)enabled
{
    NSString *safeModePath = JBROOT_PATH(@"/basebin/.safe_mode");
    if ([self isJailbroken]) {
        [self runAsRoot:^{
            [self runUnsandboxed:^{
                if (enabled) {
                    [[NSFileManager defaultManager] removeItemAtPath:safeModePath error:nil];
                }
                else {
                    [[NSData data] writeToFile:safeModePath atomically:YES];
                }
            }];
        }];
    }
}

- (BOOL)isIDownloadEnabled
{
    __block BOOL isEnabled = NO;
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            NSDictionary *disabledDict = [NSDictionary dictionaryWithContentsOfFile:@"/var/db/com.apple.xpc.launchd/disabled.plist"];
            NSNumber *idownloaddDisabledNum = disabledDict[@"com.opa334.Dopamine.idownloadd"];
            if (idownloaddDisabledNum) {
                isEnabled = ![idownloaddDisabledNum boolValue];
            }
            else {
                isEnabled = NO;
            }
        }];
    }];
    return isEnabled;
}

- (void)setIDownloadEnabled:(BOOL)enabled needsUnsandbox:(BOOL)needsUnsandbox
{
    void (^updateBlock)(void) = ^{
        if (enabled) {
            exec_cmd_trusted(JBROOT_PATH("/usr/bin/launchctl"), "enable", "system/com.opa334.Dopamine.idownloadd", NULL);
        }
        else {
            exec_cmd_trusted(JBROOT_PATH("/usr/bin/launchctl"), "disable", "system/com.opa334.Dopamine.idownloadd", NULL);
        }
    };

    if (needsUnsandbox) {
        [self runAsRoot:^{
            [self runUnsandboxed:updateBlock];
        }];
    }
    else {
        updateBlock();
    }
}

- (void)setIDownloadLoaded:(BOOL)loaded needsUnsandbox:(BOOL)needsUnsandbox
{
    if (loaded) {
        [self setIDownloadEnabled:loaded needsUnsandbox:needsUnsandbox];
    }
    
    void (^updateBlock)(void) = ^{
        if (loaded) {
            exec_cmd(JBROOT_PATH("/usr/bin/launchctl"), "load", JBROOT_PATH("/basebin/LaunchDaemons/com.opa334.Dopamine.idownloadd.plist"), NULL);
        }
        else {
            exec_cmd(JBROOT_PATH("/usr/bin/launchctl"), "unload", JBROOT_PATH("/basebin/LaunchDaemons/com.opa334.Dopamine.idownloadd.plist"), NULL);
        }
    };
    
    if (needsUnsandbox) {
        [self runAsRoot:^{
            [self runUnsandboxed:updateBlock];
        }];
    }
    else {
        updateBlock();
    }
    
    if (!loaded) {
        [self setIDownloadEnabled:loaded needsUnsandbox:needsUnsandbox];
    }
}

- (BOOL)isJailbreakHidden
{
    return ![[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb"];
}

- (void)setJailbreakHidden:(BOOL)hidden
{
    if (hidden && ![self isJailbroken] && geteuid() != 0) {
        [self runTrollStoreAction:@"hide-jailbreak"];
        return;
    }
    
    void (^actionBlock)(void) = ^{
        BOOL alreadyHidden = [self isJailbreakHidden];
        if (hidden != alreadyHidden) {
            if (hidden) {
                if ([self isJailbroken]) {
                    [self unregisterJailbreakApps];
                    [[NSFileManager defaultManager] removeItemAtPath:JBROOT_PATH(@"/basebin/.fakelib/systemhook.dylib") error:nil];
                    carbonCopy(JBROOT_PATH(@"/basebin/.dyld.orig"), JBROOT_PATH(@"/basebin/.fakelib/dyld"));
                }
                [[NSFileManager defaultManager] removeItemAtPath:@"/var/jb" error:nil];
            }
            else {
                [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/jb" withDestinationPath:JBROOT_PATH(@"/") error:nil];
                if ([self isJailbroken]) {
                    carbonCopy(JBROOT_PATH(@"/basebin/.dyld.patched"), JBROOT_PATH(@"/basebin/.fakelib/dyld"));
                    carbonCopy(JBROOT_PATH(@"/basebin/systemhook.dylib"), JBROOT_PATH(@"/basebin/.fakelib/systemhook.dylib"));
                    [self refreshJailbreakApps];
                }
            }
        }
    };
    
    if ([self isJailbroken]) {
        [self runAsRoot:^{
            [self runUnsandboxed:actionBlock];
        }];
    }
    else {
        actionBlock();
    }
}

- (NSString *)accessibleKernelPath
{
    if ([self isInstalledThroughTrollStore]) {
        NSString *kernelcachePath = [[self activePrebootPath] stringByAppendingPathComponent:@"System/Library/Caches/com.apple.kernelcaches/kernelcache"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:kernelcachePath]) {
            return kernelcachePath;
        }
        return @"/System/Library/Caches/com.apple.kernelcaches/kernelcache";
    }
    else {
        NSString *kernelInApp = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"kernelcache"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:kernelInApp]) {
            return kernelInApp;
        }
        
        [[DOUIManager sharedInstance] sendLog:@"Downloading Kernel" debug:NO];
        NSString *kernelcachePath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/kernelcache"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:kernelcachePath]) {
            if (grab_kernelcache(kernelcachePath) == false) return nil;
        }
        return kernelcachePath;
    }
}

- (BOOL)isPACBypassRequired
{
    if (![self isArm64e]) return NO;
    
    if (@available(iOS 15.2, *)) {
        return NO;
    }
    return YES;
}

- (BOOL)isPPLBypassRequired
{
    return [self isArm64e];
}

- (BOOL)isSupported
{
    //cpu_subtype_t cpuFamily = 0;
    //size_t cpuFamilySize = sizeof(cpuFamily);
    //sysctlbyname("hw.cpufamily", &cpuFamily, &cpuFamilySize, NULL, 0);
    //if (cpuFamily == CPUFAMILY_ARM_TYPHOON) return false; // A8X is unsupported for now (due to 4k page size)
    
    DOExploitManager *exploitManager = [DOExploitManager sharedManager];
    if ([exploitManager availableExploitsForType:EXPLOIT_TYPE_KERNEL].count) {
        if (![self isPACBypassRequired] || [exploitManager availableExploitsForType:EXPLOIT_TYPE_PAC].count) {
            if (![self isPPLBypassRequired] || [exploitManager availableExploitsForType:EXPLOIT_TYPE_PPL].count) {
                return true;
            }
        }
    }
    
    return false;
}

- (NSError *)prepareBootstrap
{
    __block NSError *errOut;
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    [_bootstrapper prepareBootstrapWithCompletion:^(NSError *error) {
        errOut = error;
        dispatch_semaphore_signal(sema);
    }];
    dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
    return errOut;
}

- (NSError *)finalizeBootstrap
{
    return [_bootstrapper finalizeBootstrap];
}

- (NSError *)deleteBootstrap
{
    if (![self isJailbroken] && getuid() != 0) {
        int r = [self runTrollStoreAction:@"delete-bootstrap"];
        if (r != 0) {
            // TODO: maybe handle error
        }
        return nil;
    }
    else if ([self isJailbroken]) {
        __block NSError *error;
        [self runAsRoot:^{
            [self runUnsandboxed:^{
                error = [self->_bootstrapper deleteBootstrap];
            }];
        }];
        return error;
    }
    else {
        // Let's hope for the best
        return [_bootstrapper deleteBootstrap];
    }
    [self reboot];
}

- (NSError *)reinstallPackageManagers
{
    __block NSError *error;
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            error = [self->_bootstrapper installPackageManagers];
        }];
    }];
    return error;
}


@end