//
//  Bootstrapper.m
//  Dopamine
//
//  Created by Lars Fröder on 09.01.24.
//

#import "DOBootstrapper.h"
#import "DOEnvironmentManager.h"
#import "DOUIManager.h"
#import <libjailbreak/info.h>
#import <libjailbreak/util.h>
#import <libjailbreak/jbclient_xpc.h>
#import "zstd.h"
#import <sys/mount.h>
#import <dlfcn.h>
#import <sys/stat.h>
#import "NSData+Hex.h"
#import <IOKit/IOKitLib.h>
#import <sys/sysctl.h>

#define LIBKRW_DOPAMINE_BUNDLED_VERSION @"2.0.1"
#define LIBROOT_DOPAMINE_BUNDLED_VERSION @"1.0.1"
#define BASEBIN_LINK_BUNDLED_VERSION @"1.0.0"

struct hfs_mount_args {
    char    *fspec;
    uid_t    hfs_uid;        /* uid that owns hfs files (standard HFS only) */
    gid_t    hfs_gid;        /* gid that owns hfs files (standard HFS only) */
    mode_t    hfs_mask;        /* mask to be applied for hfs perms  (standard HFS only) */
    uint32_t hfs_encoding;        /* encoding for this volume (standard HFS only) */
    struct    timezone hfs_timezone;    /* user time zone info (standard HFS only) */
    int        flags;            /* mounting flags, see below */
    int     journal_tbuffer_size;   /* size in bytes of the journal transaction buffer */
    int        journal_flags;          /* flags to pass to journal_open/create */
    int        journal_disable;        /* don't use journaling (potentially dangerous) */
};

NSString *const bootstrapErrorDomain = @"BootstrapErrorDomain";
typedef NS_ENUM(NSInteger, JBErrorCode) {
    BootstrapErrorCodeFailedToGetURL            = -1,
    BootstrapErrorCodeFailedToDownload          = -2,
    BootstrapErrorCodeFailedDecompressing       = -3,
    BootstrapErrorCodeFailedExtracting          = -4,
    BootstrapErrorCodeFailedRemount             = -5,
    BootstrapErrorCodeFailedFinalising          = -6,
    BootstrapErrorCodeFailedReplacing           = -7,
};

#define BUFFER_SIZE 8192

@implementation DOBootstrapper

- (instancetype)init
{
    self = [super init];
    if (self) {
        /*NSURLSessionConfiguration *config = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:@"com.opa334.bootstrapper.background-session"];
        _urlSession = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];*/
    }
    return self;
}

- (NSError *)decompressZstd:(NSString *)zstdPath toTar:(NSString *)tarPath
{
    // Open the input file for reading
    FILE *input_file = fopen(zstdPath.fileSystemRepresentation, "rb");
    if (input_file == NULL) {
        return [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedDecompressing userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Failed to open input file %@: %s", zstdPath, strerror(errno)]}];
    }

    // Open the output file for writing
    FILE *output_file = fopen(tarPath.fileSystemRepresentation, "wb");
    if (output_file == NULL) {
        fclose(input_file);
        return [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedDecompressing userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Failed to open output file %@: %s", tarPath, strerror(errno)]}];
    }

    // Create a ZSTD decompression context
    ZSTD_DCtx *dctx = ZSTD_createDCtx();
    if (dctx == NULL) {
        fclose(input_file);
        fclose(output_file);
        return [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedDecompressing userInfo:@{NSLocalizedDescriptionKey : @"Failed to create ZSTD decompression context"}];
    }

    // Create a buffer for reading input data
    uint8_t *input_buffer = (uint8_t *) malloc(BUFFER_SIZE);
    if (input_buffer == NULL) {
        ZSTD_freeDCtx(dctx);
        fclose(input_file);
        fclose(output_file);
        return [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedDecompressing userInfo:@{NSLocalizedDescriptionKey : @"Failed to allocate input buffer"}];
    }

    // Create a buffer for writing output data
    uint8_t *output_buffer = (uint8_t *) malloc(BUFFER_SIZE);
    if (output_buffer == NULL) {
        free(input_buffer);
        ZSTD_freeDCtx(dctx);
        fclose(input_file);
        fclose(output_file);
        return [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedDecompressing userInfo:@{NSLocalizedDescriptionKey : @"Failed to allocate output buffer"}];
    }

    // Create a ZSTD decompression stream
    ZSTD_inBuffer in = {0};
    ZSTD_outBuffer out = {0};
    ZSTD_DStream *dstream = ZSTD_createDStream();
    if (dstream == NULL) {
        free(output_buffer);
        free(input_buffer);
        ZSTD_freeDCtx(dctx);
        fclose(input_file);
        fclose(output_file);
        return [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedDecompressing userInfo:@{NSLocalizedDescriptionKey : @"Failed to create ZSTD decompression stream"}];
    }

    // Initialize the ZSTD decompression stream
    size_t ret = ZSTD_initDStream(dstream);
    if (ZSTD_isError(ret)) {
        ZSTD_freeDStream(dstream);
        free(output_buffer);
        free(input_buffer);
        ZSTD_freeDCtx(dctx);
        fclose(input_file);
        fclose(output_file);
        return [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedDecompressing userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Failed to initialize ZSTD decompression stream: %s", ZSTD_getErrorName(ret)]}];
    }
    
    // Read and decompress the input file
    size_t total_bytes_read = 0;
    size_t total_bytes_written = 0;
    size_t bytes_read;
    size_t bytes_written;
    while (1) {
        // Read input data into the input buffer
        bytes_read = fread(input_buffer, 1, BUFFER_SIZE, input_file);
        if (bytes_read == 0) {
            if (feof(input_file)) {
                // End of input file reached, break out of loop
                break;
            } else {
                ZSTD_freeDStream(dstream);
                free(output_buffer);
                free(input_buffer);
                ZSTD_freeDCtx(dctx);
                fclose(input_file);
                fclose(output_file);
                return [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedDecompressing userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Failed to read input file: %s", strerror(errno)]}];
            }
        }

        in.src = input_buffer;
        in.size = bytes_read;
        in.pos = 0;

        while (in.pos < in.size) {
            // Initialize the output buffer
            out.dst = output_buffer;
            out.size = BUFFER_SIZE;
            out.pos = 0;

            // Decompress the input data
            ret = ZSTD_decompressStream(dstream, &out, &in);
            if (ZSTD_isError(ret)) {
                ZSTD_freeDStream(dstream);
                free(output_buffer);
                free(input_buffer);
                ZSTD_freeDCtx(dctx);
                fclose(input_file);
                fclose(output_file);
                return [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedDecompressing userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Failed to decompress input data: %s", ZSTD_getErrorName(ret)]}];
            }

            // Write the decompressed data to the output file
            bytes_written = fwrite(output_buffer, 1, out.pos, output_file);
            if (bytes_written != out.pos) {
                ZSTD_freeDStream(dstream);
                free(output_buffer);
                free(input_buffer);
                ZSTD_freeDCtx(dctx);
                fclose(input_file);
                fclose(output_file);
                return [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedDecompressing userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Failed to write output file: %s", strerror(errno)]}];
            }

            total_bytes_written += bytes_written;
        }

        total_bytes_read += bytes_read;
    }

    // Clean up resources
    ZSTD_freeDStream(dstream);
    free(output_buffer);
    free(input_buffer);
    ZSTD_freeDCtx(dctx);
    fclose(input_file);
    fclose(output_file);

    return nil;
}

- (NSError *)extractTar:(NSString *)tarPath toPath:(NSString *)destinationPath
{
    int r = libarchive_unarchive(tarPath.fileSystemRepresentation, destinationPath.fileSystemRepresentation);
    if (r != 0) {
        return [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedExtracting userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"libarchive returned %d", r]}];
    }
    return nil;
}

- (BOOL)deleteSymlinkAtPath:(NSString *)path error:(NSError **)error
{
    NSDictionary<NSFileAttributeKey, id> *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:error];
    if (!attributes) return YES;
    if (attributes[NSFileType] == NSFileTypeSymbolicLink) {
        return [[NSFileManager defaultManager] removeItemAtPath:path error:error];
    }
    return NO;
}

- (BOOL)fileOrSymlinkExistsAtPath:(NSString *)path
{
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) return YES;
    
    NSDictionary<NSFileAttributeKey, id> *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    if (attributes) {
        if (attributes[NSFileType] == NSFileTypeSymbolicLink) {
            return YES;
        }
    }
    
    return NO;
}

- (NSError *)createSymlinkAtPath:(NSString *)path toPath:(NSString *)destinationPath createIntermediateDirectories:(BOOL)createIntermediate
{
    NSError *error;
    NSString *parentPath = [path stringByDeletingLastPathComponent];
    if (![[NSFileManager defaultManager] fileExistsAtPath:parentPath]) {
        if (!createIntermediate) return [NSError errorWithDomain:bootstrapErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Failed create %@->%@ symlink: Parent dir does not exists", path, destinationPath]}];
        if (![[NSFileManager defaultManager] createDirectoryAtPath:parentPath withIntermediateDirectories:YES attributes:nil error:&error]) return error;
    }
    
    [[NSFileManager defaultManager] createSymbolicLinkAtPath:path withDestinationPath:destinationPath error:&error];
    return error;
}

- (BOOL)isPrivatePrebootMountedWritable
{
    struct statfs ppStfs;
    statfs("/private/preboot", &ppStfs);
    return !(ppStfs.f_flags & MNT_RDONLY);
}

- (int)remountPrivatePrebootWritable:(BOOL)writable
{
    struct statfs ppStfs;
    int r = statfs("/private/preboot", &ppStfs);
    if (r != 0) return r;
    
    uint32_t flags = MNT_UPDATE;
    if (!writable) {
        flags |= MNT_RDONLY;
    }
    struct hfs_mount_args mntargs =
    {
        .fspec = ppStfs.f_mntfromname,
        .hfs_mask = 0,
    };
    return mount("apfs", "/private/preboot", flags, &mntargs);
}

- (NSError *)ensurePrivatePrebootIsWritable
{
    if (![self isPrivatePrebootMountedWritable]) {
        int r = [self remountPrivatePrebootWritable:YES];
        if (r != 0) {
            return [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedRemount userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Remounting /private/preboot as writable failed with error: %s", strerror(errno)]}];
        }
    }
    return nil;
}

- (void)fixupPathPermissions
{
    // Ensure the following paths are owned by root:wheel and have permissions of 755:
    // /private
    // /private/preboot
    // /private/preboot/UUID
    // /private/preboot/UUID/dopamine-<UUID>
    // /private/preboot/UUID/dopamine-<UUID>/procursus

    NSString *tmpPath = NSJBRootPath(@"/");
    while (![tmpPath isEqualToString:@"/"]) {
        struct stat s;
        stat(tmpPath.fileSystemRepresentation, &s);
        if (s.st_uid != 0 || s.st_gid != 0) {
            chown(tmpPath.fileSystemRepresentation, 0, 0);
        }
        if ((s.st_mode & S_IRWXU) != 0755) {
            chmod(tmpPath.fileSystemRepresentation, 0755);
        }
        tmpPath = [tmpPath stringByDeletingLastPathComponent];
    }
}

- (void)patchBasebinDaemonPlist:(NSString *)plistPath
{
    NSMutableDictionary *plistDict = [NSMutableDictionary dictionaryWithContentsOfFile:plistPath];
    if (plistDict) {
        bool madeChanges = NO;
        NSMutableArray *programArguments = ((NSArray *)plistDict[@"ProgramArguments"]).mutableCopy;
        for (NSString *argument in [programArguments reverseObjectEnumerator]) {
            if ([argument containsString:@"@JBROOT@"]) {
                programArguments[[programArguments indexOfObject:argument]] = [argument stringByReplacingOccurrencesOfString:@"@JBROOT@" withString:NSJBRootPath(@"/")];
                madeChanges = YES;
            }
        }
        if (madeChanges) {
            plistDict[@"ProgramArguments"] = programArguments.copy;
            [plistDict writeToFile:plistPath atomically:NO];
        }
    }
}

- (void)patchBasebinDaemonPlists
{
    NSURL *basebinDaemonsURL = [NSURL fileURLWithPath:NSJBRootPath(@"/basebin/LaunchDaemons")];
    for (NSURL *basebinDaemonURL in [[NSFileManager defaultManager] contentsOfDirectoryAtURL:basebinDaemonsURL includingPropertiesForKeys:nil options:0 error:nil]) {
        [self patchBasebinDaemonPlist:basebinDaemonURL.path];
    }
}

- (NSString *)bootstrapVersion
{
    uint64_t cfver = (((uint64_t)kCFCoreFoundationVersionNumber / 100) * 100);
    if (cfver >= 2000) {
        return nil;
    }
    return [NSString stringWithFormat:@"%llu", cfver];
}

- (NSURL *)bootstrapURL
{
    return [NSURL URLWithString:[NSString stringWithFormat:@"https://apt.procurs.us/bootstraps/%@/bootstrap-ssh-iphoneos-arm64.tar.zst", [self bootstrapVersion]]];
}

/*- (void)downloadBootstrapWithCompletion:(void (^)(NSString *path, NSError *error))completion
{
    NSURL *bootstrapURL = [self bootstrapURL];
    if (!bootstrapURL) {
        completion(nil, [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedToGetURL userInfo:@{NSLocalizedDescriptionKey : @"Failed to obtain bootstrap URL"}]);
        return;
    }
    
    _downloadCompletionBlock = ^(NSURL * _Nullable location, NSError * _Nullable error) {
        NSError *ourError;
        if (error) {
            ourError = [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedToDownload userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Failed to download bootstrap: %@", error.localizedDescription]}];
        }
        completion(location.path, ourError);
    };
    
    _bootstrapDownloadTask = [_urlSession downloadTaskWithURL:bootstrapURL];
    [_bootstrapDownloadTask resume];
}*/

- (void)extractBootstrap:(NSString *)path withCompletion:(void (^)(NSError *))completion
{
    NSString *bootstrapTar = [@"/var/tmp" stringByAppendingPathComponent:@"bootstrap.tar"];
    NSError *decompressionError = [self decompressZstd:path toTar:bootstrapTar];
    if (decompressionError) {
        completion(decompressionError);
        return;
    }
    
    decompressionError = [self extractTar:bootstrapTar toPath:@"/"];
    if (decompressionError) {
        completion(decompressionError);
        return;
    }
    
    // look, this is most probably the most inefficient way to do shit but who gives a fuck. cuz i sure dont ~ lilliana
    [[NSData data] writeToFile:NSJBRootPath(@"/.installed_dopamine") atomically:YES];
    [[NSData data] writeToFile:@"/var/.keep_symlinks" atomically:YES];
    [[NSData data] writeToFile:NSJBRootPath(@"/.mount_rw") atomically:YES];
    [[NSData data] writeToFile:NSJBRootPath(@"/xina118") atomically:YES];
    [[NSData data] writeToFile:NSJBRootPath(@"/.cydia_no_stash") atomically:YES];
    [[NSData data] writeToFile:NSJBRootPath(@"/.installed_palera1n") atomically:YES];
    [[NSData data] writeToFile:NSJBRootPath(@"/.palecursus_strapped") atomically:YES];
    [[NSData data] writeToFile:NSJBRootPath(@"/.x1links") atomically:YES];
    completion(nil);

     BOOL needsdotfiles = ![[NSFileManager defaultManager] fileExistsAtPath:@"/var/mobile/.zlogin"];
    if (needsdotfiles) {
        [[NSData data] writeToFile:@"/var/mobile/.zlogin" atomically:YES];
        [[NSData data] writeToFile:@"/var/mobile/.zlogout" atomically:YES];
        [[NSData data] writeToFile:@"/var/mobile/.zprofile" atomically:YES];
        [[NSData data] writeToFile:@"/var/mobile/.zshenv" atomically:YES];
        [[NSData data] writeToFile:@"/var/mobile/.zshrc" atomically:YES];
    }

}

- (void)prepareBootstrapWithCompletion:(void (^)(NSError *))completion
{
    [[DOUIManager sharedInstance] sendLog:@"Updating Basebins (8/12)" debug:NO];

    // Ensure /private/preboot is mounted writable (Not writable by default on iOS <=15)
    NSError *error = [self ensurePrivatePrebootIsWritable];
    if (error) {
        completion(error);
        return;
    }
    
    [self fixupPathPermissions];
    
    // Remove /var/jb as it might be wrong
    if (![self deleteSymlinkAtPath:@"/var/jb" error:&error]) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb"]) {
            if (![[NSFileManager defaultManager] removeItemAtPath:@"/var/jb" error:&error]) {
                completion([NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedReplacing userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Removing /var/jb directory failed with error: %@", error]}]);
                return;
            }
        }
        else {
            completion([NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedReplacing userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Removing /var/jb symlink failed with error: %@", error]}]);
            return;
        }
    }
    
    NSString *basebinPath = NSJBRootPath(@"/basebin");
    NSString *installedPath = NSJBRootPath(@"/.installed_dopamine");
    error = [self createSymlinkAtPath:@"/var/jb" toPath:NSJBRootPath(@"/") createIntermediateDirectories:YES];
    // most likely about to get half these symlinks wrong but the ones ik which will be wrong arent used by xinam1ne anyways so *aesthetics* dont judge me ~ lilliana
    error = [self createSymlinkAtPath:@"/var/alternatives" toPath:NSJBRootPath(@"/etc/alternatives") createIntermediateDirectories:YES];
    error = [self createSymlinkAtPath:@"/var/ap" toPath:NSJBRootPath(@"/etc/apt") createIntermediateDirectories:YES];
    error = [self createSymlinkAtPath:@"/var/ap" toPath:NSJBRootPath(@"/etc/ap") createIntermediateDirectories:YES];
    error = [self createSymlinkAtPath:@"/var/bash" toPath:NSJBRootPath(@"/bin/bash") createIntermediateDirectories:YES];
    error = [self createSymlinkAtPath:@"/var/bin" toPath:NSJBRootPath(@"/usr/bin") createIntermediateDirectories:YES];
    error = [self createSymlinkAtPath:@"/var/bzip2" toPath:NSJBRootPath(@"/usr/bin/bzip2") createIntermediateDirectories:YES];
    error = [[NSFileManager defaultManager] createDirectoryAtPath:NSJBRootPath(@"/usr/cache")]; //i know for a fact this dont exist on rego procursus ~ lilliana
    error = [self createSymlinkAtPath:@"/var/cache" toPath:NSJBRootPath(@"/usr/cache") createIntermediateDirectories:YES];
    error = [self createSymlinkAtPath:@"/var/dpkg" toPath:NSJBRootPath(@"/etc/dpkg") createIntermediateDirectories:YES];
    error = [self createSymlinkAtPath:@"/var/etc" toPath:NSJBRootPath(@"/etc") createIntermediateDirectories:YES];
    error = [self createSymlinkAtPath:@"/var/gzip" toPath:NSJBRootPath(@"/usr/bin/gzip") createIntermediateDirectories:YES];
    error = [self createSymlinkAtPath:@"/var/LIB" toPath:NSJBRootPath(@"/Library") createIntermediateDirectories:YES];
    error = [[NSFileManager defaultManager] moveItemAtPath:@"/var/lib/apt" toPath:@"/var/aptbackup"]; // turns out apt is important so back this up first ~ lilliana
    error = [[NSFileManager defaultManager] removeItemAtPath:@"/var/lib"]; // var lib is usually filled with shit so get rid of it before making the link ~ lilliana
    error = [self createSymlinkAtPath:@"/var/lib" toPath:NSJBRootPath(@"/usr/lib") createIntermediateDirectories:YES];
    error = [[NSFileManager defaultManager] moveItemAtPath:@"/var/aptbackup" toPath:@"/var/lib/apt"];
    error = [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/lib/ex"];
    error = [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/lib/misc"];
    error = [self createSymlinkAtPath:@"/var/lib/dpkg" toPath:NSJBRootPath(@"/Library/dpkg") createIntermediateDirectories:YES];
    error = [self createSymlinkAtPath:@"/var/Lib" toPath:NSJBRootPath(@"/usr/lib") createIntermediateDirectories:YES];
    error = [self createSymlinkAtPath:@"/var/libexec" toPath:NSJBRootPath(@"/usr/libexec") createIntermediateDirectories:YES];
    error = [self createSymlinkAtPath:@"/var/Library" toPath:NSJBRootPath(@"/Library") createIntermediateDirectories:YES];
    error = [self createSymlinkAtPath:@"/var/LIY" toPath:NSJBRootPath(@"/Library") createIntermediateDirectories:YES];
    error = [self createSymlinkAtPath:@"/var/LIy" toPath:NSJBRootPath(@"/Library") createIntermediateDirectories:YES];
    error = [self createSymlinkAtPath:@"/var/Liy" toPath:NSJBRootPath(@"/Library") createIntermediateDirectories:YES];
    error = [self createSymlinkAtPath:@"/var/local" toPath:NSJBRootPath(@"/usr/local") createIntermediateDirectories:YES];
    error = [self createSymlinkAtPath:@"/var/master.passwd" toPath:NSJBRootPath(@"/etc/master.passwd") createIntermediateDirectories:YES];
    error = [self createSymlinkAtPath:@"/var/newuser" toPath:NSJBRootPath(@"/usr/sbin/adduser") createIntermediateDirectories:YES];
    error = [self createSymlinkAtPath:@"/var/LIY" toPath:NSJBRootPath(@"/Library") createIntermediateDirectories:YES];
    error = [self createSymlinkAtPath:@"/var/profile" toPath:NSJBRootPath(@"/etc/profile") createIntermediateDirectories:YES];
    error = [self createSymlinkAtPath:@"/var/sbin" toPath:NSJBRootPath(@"/usr/sbin") createIntermediateDirectories:YES];
    error = [self createSymlinkAtPath:@"/var/sh" toPath:NSJBRootPath(@"/bin/sh") createIntermediateDirectories:YES];
    error = [self createSymlinkAtPath:@"/var/share" toPath:NSJBRootPath(@"/usr/share") createIntermediateDirectories:YES];
    error = [self createSymlinkAtPath:@"/var/LIY" toPath:NSJBRootPath(@"/Library") createIntermediateDirectories:YES];
    error = [self createSymlinkAtPath:@"/var/ssh" toPath:NSJBRootPath(@"/etc/ssh") createIntermediateDirectories:YES];
    error = [self createSymlinkAtPath:@"/var/LIY" toPath:NSJBRootPath(@"/Library") createIntermediateDirectories:YES];
    error = [self createSymlinkAtPath:@"/var/sudo_logsrvd.conf" toPath:NSJBRootPath(@"/etc/sudo_logsrvd.conf") createIntermediateDirectories:YES];
    error = [self createSymlinkAtPath:@"/var/sy" toPath:NSJBRootPath(@"/System") createIntermediateDirectories:YES];
    error = [[NSFileManager defaultManager] createDirectoryAtPath:NSJBRootPath(@"/Library/Themes")];
    error = [self createSymlinkAtPath:@"/var/Themes" toPath:NSJBRootPath(@"/Library/Themes") createIntermediateDirectories:YES];
    error = [self createSymlinkAtPath:@"/var/ubi" toPath:NSJBRootPath(@"/usr/bin") createIntermediateDirectories:YES];
    error = [self createSymlinkAtPath:@"/var/ulb" toPath:NSJBRootPath(@"/usr/lib") createIntermediateDirectories:YES];
    error = [self createSymlinkAtPath:@"/var/usr" toPath:NSJBRootPath(@"/usr") createIntermediateDirectories:YES];
    error = [self createSymlinkAtPath:@"/var/zlogin" toPath:@"/var/mobile/.zlogin" createIntermediateDirectories:YES];
    error = [self createSymlinkAtPath:@"/var/zlogout" toPath:@"/var/mobile/.zlogout" createIntermediateDirectories:YES];
    error = [self createSymlinkAtPath:@"/var/zprofile" toPath:@"/var/mobile/.zprofile" createIntermediateDirectories:YES];
    error = [self createSymlinkAtPath:@"/var/zshenv" toPath:@"/var/mobile/.zshenv" createIntermediateDirectories:YES];
    error = [self createSymlinkAtPath:@"/var/zshrc" toPath:@"/var/mobile/.zshrc" createIntermediateDirectories:YES];
    error = [self createSymlinkAtPath:@"/var/zsh" toPath:NSJBRootPath(@"/bin/zsh") createIntermediateDirectories:YES];
    error = [[NSFileManager defaultManager] removeItemAtPath:NSJBRootPath(@"/var")];
    error = [self createSymlinkAtPath:NSJBRootPath(@"/var") toPath:@"/var" createIntermediateDirectories:YES];
    error = [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/cache"];
    error = [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/cache/apt"];
    error = [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/cache/apt/archives"];
    error = [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/cache/apt/archives/partial"];
    error = [[NSData data] writeToFile:@"/var/cache/apt/archives/lock" atomically:YES];
    error = [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/cache/dpkg"];
    error = [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/cache/dpkg/log"];
    error = [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/cache/locate"];
    error = [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/lock"];
    error = [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/mnt"];
    error = [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/null"];
    error = [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/opt"];
    error = [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/select"];
    error = [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/stash"];
    error = [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/backups"];
    error = [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/spool"];
    error = [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/account"];
    error = [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/crash"];
    error = [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/account"];
    error = [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/games"];
    error = [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/account"];
    error = [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/mail"];
    error = [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/stash"];
    error = [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/www"];
    error = [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/yp"];
    error = [[NSFileManager defaultManager] removeItemAtPath:NSJBRootPath(@"/dev")];
    error = [[NSFileManager defaultManager] removeItemAtPath:NSJBRootPath(@"/tmp")];
    error = [self createSymlinkAtPath:@"/var/jb/dev" toPath:@"/dev" createIntermediateDirectories:YES];
    error = [self createSymlinkAtPath:NSJBRootPath(@"/Xapps") toPath:NSJBRootPath(@"/Applications") createIntermediateDirectories:YES];
    error = [self createSymlinkAtPath:@"/var/mobile/Library" toPath:NSJBRootPath(@"/UsrLb") createIntermediateDirectories:YES];
    error = [self createSymlinkAtPath:@"/var/mobile" toPath:NSJBRootPath(@"/vmo") createIntermediateDirectories:YES];
    error = [self createSymlinkAtPath:NSJBRootPath(@"/tmp") toPath:@"/var/tmp" createIntermediateDirectories:YES];
    error = [[NSFileManager defaultManager] createDirectoryAtPath:NSJBRootPath(@"/private")];
    error = [[NSFileManager defaultManager] createDirectoryAtPath:NSJBRootPath(@"/private/system_data")];
    error = [self createSymlinkAtPath:NSJBRootPath(@"/private/preboot") toPath:@"/private/preboot" createIntermediateDirectories:YES];
    error = [self createSymlinkAtPath:NSJBRootPath(@"/private/var") toPath:@"/var" createIntermediateDirectories:YES];
    error = [self createSymlinkAtPath:NSJBRootPath(@"/private/xarts") toPath:@"/private/xarts" createIntermediateDirectories:YES];
    error = [[NSFileManager defaultManager] moveItemAtPath:NSJBRootPath(@"/etc") toPath:NSJBRootPath(@"/private/etc")];
    error = [self createSymlinkAtPath:NSJBRootPath(@"/etc") toPath:NSJBRootPath(@"/private/etc") createIntermediateDirectories:YES];
    error = [[NSFileManager defaultManager] createDirectoryAtPath:NSJBRootPath(@"/AppleInternal")];
    error = [[NSFileManager defaultManager] createDirectoryAtPath:NSJBRootPath(@"/Developer")];
    error = [[NSFileManager defaultManager] createDirectoryAtPath:NSJBRootPath(@"/cores")];
    error = [[NSFileManager defaultManager] createDirectoryAtPath:NSJBRootPath(@"/.mb")];
    error = [[NSFileManager defaultManager] createDirectoryAtPath:NSJBRootPath(@"/.ba")];
    error = [[NSFileManager defaultManager] createDirectoryAtPath:NSJBRootPath(@"/.fseventsd")];
    error = [[NSFileManager defaultManager] createDirectoryAtPath:NSJBRootPath(@"/System/Cryptexes")];
    error = [[NSFileManager defaultManager] createDirectoryAtPath:NSJBRootPath(@"/System/Applications")];
    error = [[NSFileManager defaultManager] createDirectoryAtPath:NSJBRootPath(@"/System/Developer")];
    error = [[NSFileManager defaultManager] createDirectoryAtPath:NSJBRootPath(@"/System/DriverKit")];
    error = [self createSymlinkAtPath:NSJBRootPath(@"/System/Cryptexes/App") toPath:@"/private/preboot/Cryptexes/App" createIntermediateDirectories:YES];
    error = [self createSymlinkAtPath:NSJBRootPath(@"/System/Cryptexes/OS") toPath:@"/private/preboot/Cryptexes/OS" createIntermediateDirectories:YES];
    error = [[NSData data] writeToFile:NSJBRootPath(@"/.file") atomically:YES];
    error = [[NSData data] writeToFile:@"/var/.updated" atomically:YES];
    if (error) {
        completion(error);
        return;
    }
    
    if ([[NSFileManager defaultManager] fileExistsAtPath:basebinPath]) {
        if (![[NSFileManager defaultManager] removeItemAtPath:basebinPath error:&error]) {
            completion([NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedExtracting userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Failed deleting existing basebin file with error: %@", error.localizedDescription]}]);
            return;
        }
    }
    error = [self extractTar:[[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"basebin.tar"] toPath:NSJBRootPath(@"/")];
    if (error) {
        completion(error);
        return;
    }
    [self patchBasebinDaemonPlists];
    [[NSFileManager defaultManager] removeItemAtPath:NSJBRootPath(@"/basebin/basebin.tc") error:nil];
    
    void (^bootstrapFinishedCompletion)(NSError *) = ^(NSError *error){
        if (error) {
            completion(error);
            return;
        }
        
        NSString *defaultSources = @"Types: deb\n"
            @"URIs: https://repo.chariz.com/\n"
            @"Suites: ./\n"
            @"Components:\n"
            @"\n"
            @"Types: deb\n"
            @"URIs: https://havoc.app/\n"
            @"Suites: ./\n"
            @"Components:\n"
            @"\n"
            @"Types: deb\n"
            @"URIs: http://apt.thebigboss.org/repofiles/cydia/\n"
            @"Suites: stable\n"
            @"Components: main\n"
            @"\n"
            @"Types: deb\n"
            @"URIs: https://ellekit.space/\n"
            @"Suites: ./\n"
            @"Components:\n";
        [defaultSources writeToFile:NSJBRootPath(@"/etc/apt/sources.list.d/default.sources") atomically:NO encoding:NSUTF8StringEncoding error:nil];
        
        NSString *mobilePreferencesPath = NSJBRootPath(@"/var/mobile/Library/Preferences");
        if (![[NSFileManager defaultManager] fileExistsAtPath:mobilePreferencesPath]) {
            NSDictionary<NSFileAttributeKey, id> *attributes = @{
                NSFilePosixPermissions : @0755,
                NSFileOwnerAccountID : @501,
                NSFileGroupOwnerAccountID : @501,
            };
            [[NSFileManager defaultManager] createDirectoryAtPath:mobilePreferencesPath withIntermediateDirectories:YES attributes:attributes error:nil];
        }
        

        completion(nil);
    };
    
    
    BOOL needsBootstrap = ![[NSFileManager defaultManager] fileExistsAtPath:installedPath];
    if (needsBootstrap) {
        // First, wipe any existing content that's not basebin
        for (NSURL *subItemURL in [[NSFileManager defaultManager] contentsOfDirectoryAtURL:[NSURL fileURLWithPath:NSJBRootPath(@"/")] includingPropertiesForKeys:nil options:0 error:nil]) {
            if (![subItemURL.lastPathComponent isEqualToString:@"basebin"]) {
                [[NSFileManager defaultManager] removeItemAtURL:subItemURL error:nil];
            }
        }
        
        /*void (^bootstrapDownloadCompletion)(NSString *, NSError *) = ^(NSString *path, NSError *error) {
            if (error) {
                completion(error);
                return;
            }
            [self extractBootstrap:path withCompletion:bootstrapFinishedCompletion];
        };*/
        
        [[DOUIManager sharedInstance] sendLog:@"Extracting Bootstrap" debug:NO];

        NSString *bootstrapZstdPath = [NSString stringWithFormat:@"%@/bootstrap_%@.tar.zst", [NSBundle mainBundle].bundlePath, [self bootstrapVersion]];
        [self extractBootstrap:bootstrapZstdPath withCompletion:bootstrapFinishedCompletion];

        /*NSString *documentsCandidate = @"/var/mobile/Documents/bootstrap.tar.zstd";
        NSString *bundleCandidate = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"bootstrap.tar.zstd"];
        // Check if the user provided a bootstrap
        if ([[NSFileManager defaultManager] fileExistsAtPath:documentsCandidate]) {
            bootstrapDownloadCompletion(documentsCandidate, nil);
        }
        else if ([[NSFileManager defaultManager] fileExistsAtPath:bundleCandidate]) {
            bootstrapDownloadCompletion(bundleCandidate, nil);
        }
        else {
            [[DOUIManager sharedInstance] sendLog:@"Downloading Bootstrap" debug:NO];
            [self downloadBootstrapWithCompletion:bootstrapDownloadCompletion];
        }*/
    }
    else {
        bootstrapFinishedCompletion(nil);
    }
}

- (int)installPackage:(NSString *)packagePath
{
    if (getuid() == 0) {
        return exec_cmd_trusted(JBRootPath("/usr/bin/dpkg"), "-i", packagePath.fileSystemRepresentation, NULL);
    }
    else {
        // idk why but waitpid sometimes fails and this returns -1, so we just ignore the return value
        exec_cmd(JBRootPath("/basebin/jbctl"), "internal", "install_pkg", packagePath.fileSystemRepresentation, NULL);
        return 0;
    }
}

- (int)uninstallPackageWithIdentifier:(NSString *)identifier
{
    return exec_cmd_trusted(JBRootPath("/usr/bin/dpkg"), "-r", identifier.UTF8String, NULL);
}

- (NSString *)installedVersionForPackageWithIdentifier:(NSString *)identifier
{
    NSString *dpkgStatus = [NSString stringWithContentsOfFile:NSJBRootPath(@"/var/lib/dpkg/status") encoding:NSUTF8StringEncoding error:nil];
    NSString *packageStartLine = [NSString stringWithFormat:@"Package: %@", identifier];
    
    NSArray *packageInfos = [dpkgStatus componentsSeparatedByString:@"\n\n"];
    for (NSString *packageInfo in packageInfos) {
        if ([packageInfo hasPrefix:packageStartLine]) {
            __block NSString *version = nil;
            [packageInfo enumerateLinesUsingBlock:^(NSString * _Nonnull line, BOOL * _Nonnull stop) {
                if ([line hasPrefix:@"Version: "]) {
                    version = [line substringFromIndex:9];
                }
            }];
            return version;
        }
    }
    return nil;
}

- (NSError *)installPackageManagers
{
    NSArray *enabledPackageManagers = [[DOUIManager sharedInstance] enabledPackageManagers];
    for (NSDictionary *packageManagerDict in enabledPackageManagers) {
        NSString *path = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:packageManagerDict[@"Package"]];
        NSString *name = packageManagerDict[@"Display Name"];
        int r = [self installPackage:path];
        if (r != 0) {
            return [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedFinalising userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Failed to install %@: %d\n", name, r]}];
        }
    }
    return nil;
}

- (NSError *)finalizeBootstrap
{
    // Initial setup on first jailbreak
    if ([[NSFileManager defaultManager] fileExistsAtPath:NSJBRootPath(@"/prep_bootstrap.sh")]) {
        [[DOUIManager sharedInstance] sendLog:@"Finalizing Bootstrap" debug:NO];
        int r = exec_cmd_trusted(JBRootPath("/bin/sh"), JBRootPath("/prep_bootstrap.sh"), NULL);
        if (r != 0) {
            return [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedFinalising userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"prep_bootstrap.sh returned %d\n", r]}];
        }
        
        NSError *error = [self installPackageManagers];
        if (error) return error;
    }
    
    NSString *librootInstalledVersion = [self installedVersionForPackageWithIdentifier:@"libroot-dopamine"];
    NSString *libkrwDopamineInstalledVersion = [self installedVersionForPackageWithIdentifier:@"libkrw0-dopamine"];
    NSString *basebinLinkInstalledVersion = [self installedVersionForPackageWithIdentifier:@"dopamine-basebin-link"];
    
    if (!librootInstalledVersion || ![librootInstalledVersion isEqualToString:LIBROOT_DOPAMINE_BUNDLED_VERSION] ||
        !libkrwDopamineInstalledVersion || ![libkrwDopamineInstalledVersion isEqualToString:LIBKRW_DOPAMINE_BUNDLED_VERSION] ||
        !basebinLinkInstalledVersion || ![basebinLinkInstalledVersion isEqualToString:BASEBIN_LINK_BUNDLED_VERSION]) {
        [[DOUIManager sharedInstance] sendLog:@"Updating Bundled Packages" debug:NO];
        if (!librootInstalledVersion || ![librootInstalledVersion isEqualToString:LIBROOT_DOPAMINE_BUNDLED_VERSION]) {
            NSString *librootPath = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"libroot.deb"];
            int r = [self installPackage:librootPath];
            if (r != 0) return [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedFinalising userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Failed to install libroot: %d\n", r]}];
        }
        
        if (!libkrwDopamineInstalledVersion || ![libkrwDopamineInstalledVersion isEqualToString:LIBKRW_DOPAMINE_BUNDLED_VERSION]) {
            NSString *libkrwPath = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"libkrw-plugin.deb"];
            int r = [self installPackage:libkrwPath];
            if (r != 0) return [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedFinalising userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Failed to install the libkrw plugin: %d\n", r]}];
        }
        
        if (!basebinLinkInstalledVersion || ![basebinLinkInstalledVersion isEqualToString:BASEBIN_LINK_BUNDLED_VERSION]) {
            // Clean symlinks from earlier Dopamine versions
            if (![self fileOrSymlinkExistsAtPath:NSJBRootPath(@"/usr/bin/opainject")]) {
                [[NSFileManager defaultManager] removeItemAtPath:NSJBRootPath(@"/usr/bin/opainject") error:nil];
            }
            if (![self fileOrSymlinkExistsAtPath:NSJBRootPath(@"/usr/bin/jbctl")]) {
                [[NSFileManager defaultManager] removeItemAtPath:NSJBRootPath(@"/usr/bin/jbctl") error:nil];
            }
            if (![self fileOrSymlinkExistsAtPath:NSJBRootPath(@"/usr/lib/libjailbreak.dylib")]) {
                [[NSFileManager defaultManager] removeItemAtPath:NSJBRootPath(@"/usr/lib/libjailbreak.dylib") error:nil];
            }
            if (![self fileOrSymlinkExistsAtPath:NSJBRootPath(@"/usr/bin/libjailbreak.dylib")]) {
                // Yes this exists >.< was a typo
                [[NSFileManager defaultManager] removeItemAtPath:NSJBRootPath(@"/usr/bin/libjailbreak.dylib") error:nil];
            }
            
            NSString *basebinLinkPath = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"basebin-link.deb"];
            int r = [self installPackage:basebinLinkPath];
            if (r != 0) return [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedFinalising userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Failed to install basebin link: %d\n", r]}];
        }
    }

    return nil;
}

- (NSError *)deleteBootstrap
{
    NSError *error = [self ensurePrivatePrebootIsWritable];
    if (error) return error;
    NSString *path = [[NSString stringWithUTF8String:gSystemInfo.jailbreakInfo.rootPath] stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] removeItemAtPath:path error:&error];
    if (error) return error;
    [[NSFileManager defaultManager] removeItemAtPath:@"/var/jb" error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:@"/var/.keep_symlinks" error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:@"/var/alternatives" error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:@"/var/ap" error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:@"/var/apt" error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:@"/var/bash" error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:@"/var/bzip2" error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:@"/var/cache" error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:@"/var/dpkg" error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:@"/var/etc" error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:@"/var/gzip" error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:@"/var/LIB" error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:@"/var/Lib" error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:@"/var/lib" error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:@"/var/libexec" error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:@"/var/LIY" error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:@"/var/Library" error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:@"/var/LIy" error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:@"/var/Liy" error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:@"/var/local" error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:@"/var/master.passwd" error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:@"/var/newuser" error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:@"/var/profile" error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:@"/var/sh" error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:@"/var/share" error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:@"/var/ssh" error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:@"/var/sy" error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:@"/var/Themes" error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:@"/var/sudo_logsrvd.conf" error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:@"/var/ubi" error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:@"/var/ulb" error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:@"/var/usr" error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:@"/var/zlogin" error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:@"/var/zlogout" error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:@"/var/zprofile" error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:@"/var/zsh" error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:@"/var/zshenv" error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:@"/var/zshrc" error:nil];
    return error;
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite
{
    if (downloadTask == _bootstrapDownloadTask) {
        NSString *sizeString = [NSByteCountFormatter stringFromByteCount:totalBytesWritten countStyle:NSByteCountFormatterCountStyleFile];
        NSString *writtenBytesString = [NSByteCountFormatter stringFromByteCount:totalBytesExpectedToWrite countStyle:NSByteCountFormatterCountStyleFile];
        
        [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"Downloading Bootstrap (%@/%@)", sizeString, writtenBytesString] debug:NO update:YES];
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
    _downloadCompletionBlock(nil, error);
}

- (void)URLSession:(nonnull NSURLSession *)session downloadTask:(nonnull NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(nonnull NSURL *)location
{
    _downloadCompletionBlock(location, nil);
}

@end
