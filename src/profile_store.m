#import "profile_store.h"
#include <sys/file.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>

static const NSUInteger maxConfigBytes=4*1024*1024;
static const NSUInteger maxRetired=256;

@implementation EPStoredProfile
@end
@implementation EPConfiguration
- (instancetype)init {
    if ((self=[super init])) { _profiles=[NSMutableArray array]; _retired=[NSMutableArray array]; }
    return self;
}
- (NSArray<NSData *> *)knownOverrides {
    NSMutableArray *values=[self.retired mutableCopy];
    for (EPStoredProfile *p in self.profiles)
        if (![values containsObject:p.custom]) [values addObject:p.custom];
    return values;
}
@end

static void fail(NSError **error, NSString *message) {
    if (error) *error=[NSError errorWithDomain:@"EDIDProfiles" code:1
        userInfo:@{NSLocalizedDescriptionKey:message}];
}
int ep_store_error(NSError *error) {
    fprintf(stderr,"%s\n",(error.localizedDescription ?: @"Profile operation failed.").UTF8String);
    return 1;
}
NSString *ep_root(void) {
    const char *testRoot=getenv("EDID_OVERRIDE_ROOT");
    if (testRoot && testRoot[0]) return [[NSString stringWithUTF8String:testRoot] stringByStandardizingPath];
    return [NSHomeDirectory() stringByAppendingPathComponent:@".config/edid-override"];
}
NSString *ep_config_path(void) { return [ep_root() stringByAppendingPathComponent:@"profiles.json"]; }

BOOL ep_name_valid(NSString *name) {
    if (![name isKindOfClass:NSString.class] || !name.length || name.length>64) return NO;
    const char *s=name.UTF8String;
    if (!s || !((s[0]>='a' && s[0]<='z') || (s[0]>='0' && s[0]<='9'))) return NO;
    for (size_t i=0; s[i]; ++i)
        if (!((s[i]>='a' && s[i]<='z') || (s[i]>='0' && s[i]<='9') || s[i]=='-' || s[i]=='_')) return NO;
    return YES;
}

NSData *ep_read_edid(NSString *path, NSError **error) {
    NSString *expanded=[path stringByExpandingTildeInPath];
    NSDictionary *attributes=[[NSFileManager defaultManager] attributesOfItemAtPath:expanded error:error];
    if (!attributes || [attributes[NSFileSize] unsignedLongLongValue]>EP_MAX_EDID_BYTES) {
        fail(error,@"EDID is missing or exceeds 4096 bytes."); return nil;
    }
    NSData *data=[NSData dataWithContentsOfFile:expanded options:0 error:error];
    if (!data || !ep_edid_valid(data.bytes,data.length)) {
        fail(error,@"Invalid EDID: check its header, length, extension count, and block checksums."); return nil;
    }
    return data;
}

EPStoredProfile *ep_make_profile(NSString *name, NSData *factory, NSData *custom, BOOL enabled, NSError **error) {
    if (!ep_name_valid(name)) { fail(error,@"Use a profile name of 1-64 lowercase letters, digits, hyphens or underscores."); return nil; }
    if (!factory || !custom || !ep_profile_edids_compatible(factory.bytes,factory.length,custom.bytes,custom.length)) {
        fail(error,@"Factory and custom EDIDs must be valid, identify the same unit, and retain at least one usable serial. Preserve its identity fields when editing timings.");
        return nil;
    }
    EPIdentity identity;
    if (!ep_identity(factory.bytes,factory.length,false,&identity)) return nil;
    EPStoredProfile *p=[[EPStoredProfile alloc] init];
    p.name=name; p.factory=factory; p.custom=custom; p.enabled=enabled; p.identity=identity;
    return p;
}

static BOOL isSymlink(NSString *path) {
    struct stat info;
    return lstat(path.fileSystemRepresentation,&info)==0 && S_ISLNK(info.st_mode);
}

EPConfiguration *ep_read_config(NSString *path, BOOL allowMissing, NSError **error) {
    NSFileManager *fm=[NSFileManager defaultManager];
    if (isSymlink(path)) { fail(error,@"Refusing a symlinked profile configuration."); return nil; }
    if (![fm fileExistsAtPath:path]) {
        if (allowMissing) return [[EPConfiguration alloc] init];
        fail(error,@"Profile configuration not found. Run the installer first."); return nil;
    }
    NSDictionary *attrs=[fm attributesOfItemAtPath:path error:error];
    if (!attrs || [attrs[NSFileSize] unsignedLongLongValue]>maxConfigBytes) {
        fail(error,@"Profile configuration is missing or too large."); return nil;
    }
    NSData *bytes=[NSData dataWithContentsOfFile:path options:0 error:error];
    if (!bytes || bytes.length>maxConfigBytes) return nil;
    id object=[NSJSONSerialization JSONObjectWithData:bytes options:0 error:error];
    if (![object isKindOfClass:NSDictionary.class]) { fail(error,@"Configuration must be a JSON object."); return nil; }
    NSDictionary *json=object;
    NSArray *rows=json[@"profiles"];
    id rawVersion=json[@"version"];
    if (![rawVersion isKindOfClass:NSNumber.class] || [rawVersion integerValue]!=2 ||
        ![rows isKindOfClass:NSArray.class] || rows.count>EP_MAX_PROFILES) {
        fail(error,@"Expected profile configuration version 2, with at most 64 profiles."); return nil;
    }
    EPConfiguration *config=[[EPConfiguration alloc] init];
    NSMutableSet *names=[NSMutableSet set];
    for (id row in rows) {
        if (![row isKindOfClass:NSDictionary.class]) { fail(error,@"Invalid profile record."); return nil; }
        NSString *name=row[@"name"];
        id enabled=row[@"enabled"];
        NSString *factory64=row[@"factoryEDID"], *custom64=row[@"overrideEDID"];
        if (!ep_name_valid(name) || [names containsObject:name] || ![enabled isKindOfClass:NSNumber.class] ||
            CFGetTypeID((__bridge CFTypeRef)enabled)!=CFBooleanGetTypeID() ||
            ![factory64 isKindOfClass:NSString.class] || ![custom64 isKindOfClass:NSString.class]) {
            fail(error,@"Invalid or duplicate profile name, enabled flag, or EDID payload."); return nil;
        }
        NSData *factory=[[NSData alloc] initWithBase64EncodedString:factory64 options:0];
        NSData *custom=[[NSData alloc] initWithBase64EncodedString:custom64 options:0];
        EPStoredProfile *p=ep_make_profile(name,factory,custom,[enabled boolValue],error);
        if (!p) return nil;
        [config.profiles addObject:p]; [names addObject:name];
    }
    id retired=json[@"retiredOverrides"] ?: @[];
    if (![retired isKindOfClass:NSArray.class] || [retired count]>maxRetired) {
        fail(error,@"Invalid retired-override history."); return nil;
    }
    for (id encoded in retired) {
        if (![encoded isKindOfClass:NSString.class]) { fail(error,@"Invalid retired EDID."); return nil; }
        NSData *data=[[NSData alloc] initWithBase64EncodedString:encoded options:0];
        if (!data || !ep_edid_valid(data.bytes,data.length)) { fail(error,@"Invalid retired EDID."); return nil; }
        if (![config.retired containsObject:data]) [config.retired addObject:data];
    }
    return config;
}

BOOL ep_write_config(EPConfiguration *config, NSString *path, NSError **error) {
    if (isSymlink(path)) { fail(error,@"Refusing a symlinked profile configuration."); return NO; }
    NSMutableArray *profiles=[NSMutableArray array], *retired=[NSMutableArray array];
    for (EPStoredProfile *p in config.profiles)
        [profiles addObject:@{@"name":p.name,@"enabled":@(p.enabled),
            @"factoryEDID":[p.factory base64EncodedStringWithOptions:0],
            @"overrideEDID":[p.custom base64EncodedStringWithOptions:0]}];
    for (NSData *data in config.retired) [retired addObject:[data base64EncodedStringWithOptions:0]];
    NSData *json=[NSJSONSerialization dataWithJSONObject:@{@"version":@2,@"profiles":profiles,@"retiredOverrides":retired}
        options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:error];
    if (!json || json.length>maxConfigBytes) { fail(error,@"Configuration exceeds its size limit."); return NO; }
    if (![[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
        withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error]) return NO;
    if (![json writeToFile:path options:NSDataWritingAtomic error:error]) return NO;
    return [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:path error:error];
}

int ep_list_profiles(void) {
    NSError *error=nil;
    EPConfiguration *config=ep_read_config(ep_config_path(),NO,&error);
    if (!config) return ep_store_error(error);
    printf("Profiles: %lu\n",(unsigned long)config.profiles.count);
    for (EPStoredProfile *p in config.profiles) {
        EPIdentity identity=p.identity;
        printf("%s  %s  vendor=%04X product=%04X numeric=%u text=%s\n",p.name.UTF8String,
            p.enabled ? "enabled" : "disabled",identity.vendor,identity.product,identity.numeric_serial,
            identity.has_text ? identity.text_serial : "(none)");
    }
    return 0;
}

static BOOL retire(EPConfiguration *config, NSData *data, NSError **error) {
    if ([config.retired containsObject:data]) return YES;
    if (config.retired.count>=maxRetired) { fail(error,@"Retired override history is full; no changes made."); return NO; }
    [config.retired addObject:data]; return YES;
}

int ep_change_profile(NSString *action, NSString *name, NSString *factoryPath, NSString *customPath) {
    if (!ep_name_valid(name)) { fprintf(stderr,"Invalid profile name.\n"); return 1; }
    NSError *error=nil;
    NSFileManager *fm=[NSFileManager defaultManager];
    if (isSymlink(ep_root())) { fprintf(stderr,"Refusing a symlinked installation directory.\n"); return 1; }
    if (![fm createDirectoryAtPath:ep_root() withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error])
        return ep_store_error(error);
    NSString *lockPath=[ep_root() stringByAppendingPathComponent:@"profiles.lock"];
    int fd=open(lockPath.fileSystemRepresentation,O_RDWR|O_CREAT|O_NOFOLLOW,0600);
    if (fd<0 || flock(fd,LOCK_EX)!=0) { if (fd>=0) close(fd); perror("Profile lock"); return 1; }
    int result=1;
    do {
        EPConfiguration *config=ep_read_config(ep_config_path(),YES,&error);
        if (!config) break;
        NSUInteger index=[config.profiles indexOfObjectPassingTest:^BOOL(EPStoredProfile *p, NSUInteger i, BOOL *stop) {
            (void)i; (void)stop; return [p.name isEqualToString:name];
        }];
        EPStoredProfile *old=index==NSNotFound ? nil : config.profiles[index];
        if ([action isEqualToString:@"add"] || [action isEqualToString:@"replace"]) {
            if (([action isEqualToString:@"add"] && old) || ([action isEqualToString:@"replace"] && !old)) {
                fail(&error,old ? @"That name already exists. Use --replace to replace it." : @"Profile not found."); break;
            }
            NSData *factory=ep_read_edid(factoryPath,&error);
            NSData *custom=factory ? ep_read_edid(customPath,&error) : nil;
            EPStoredProfile *fresh=custom ? ep_make_profile(name,factory,custom,old ? old.enabled : YES,&error) : nil;
            if (!fresh) break;
            BOOL conflict=NO;
            for (EPStoredProfile *p in config.profiles) {
                EPIdentity a=p.identity, b=fresh.identity;
                if (p!=old && p.enabled && fresh.enabled && (ep_matches(&a,&b)||ep_matches(&b,&a))) conflict=YES;
            }
            if (conflict) { fail(&error,@"Another enabled profile overlaps this monitor. Disable it first."); break; }
            if (old) {
                if (!retire(config,old.custom,&error)) break;
                config.profiles[index]=fresh;
            } else {
                if (config.profiles.count>=EP_MAX_PROFILES) { fail(&error,@"Profile limit reached."); break; }
                [config.profiles addObject:fresh];
            }
        } else if ([action isEqualToString:@"remove"]) {
            if (!old) { fail(&error,@"Profile not found."); break; }
            if (!retire(config,old.custom,&error)) break;
            [config.profiles removeObjectAtIndex:index];
        } else if ([action isEqualToString:@"disable-profile"]) {
            if (!old) { fail(&error,@"Profile not found."); break; }
            if (!retire(config,old.custom,&error)) break;
            old.enabled=NO;
        } else if ([action isEqualToString:@"enable-profile"]) {
            if (!old) { fail(&error,@"Profile not found."); break; }
            BOOL conflict=NO;
            for (EPStoredProfile *p in config.profiles) {
                EPIdentity a=p.identity,b=old.identity;
                if (p!=old && p.enabled && (ep_matches(&a,&b)||ep_matches(&b,&a))) conflict=YES;
            }
            if (conflict) { fail(&error,@"Another enabled profile overlaps this monitor."); break; }
            old.enabled=YES;
        } else { fail(&error,@"Unknown profile action."); break; }
        if (!ep_write_config(config,ep_config_path(),&error)) break;
        printf("Profile '%s': %s. A running daemon reloads changes within five seconds.\n",name.UTF8String,action.UTF8String);
        result=0;
    } while (0);
    (void)flock(fd,LOCK_UN); close(fd);
    if (result) ep_store_error(error);
    return result;
}

int ep_prepare_config(NSString *defaultsPath, NSString *outputPath) {
    NSError *error=nil;
    EPConfiguration *defaults=ep_read_config(defaultsPath,NO,&error);
    EPConfiguration *config=defaults ? ep_read_config(ep_config_path(),YES,&error) : nil;
    if (!config) return ep_store_error(error);
    for (EPStoredProfile *fresh in defaults.profiles) {
        BOOL exists=NO;
        for (EPStoredProfile *old in config.profiles) {
            EPIdentity a=fresh.identity,b=old.identity;
            if ([fresh.name isEqualToString:old.name] || ep_matches(&a,&b) || ep_matches(&b,&a)) exists=YES;
        }
        if (!exists) {
            if (config.profiles.count>=EP_MAX_PROFILES) { fprintf(stderr,"Profile limit reached.\n"); return 1; }
            [config.profiles addObject:fresh];
        }
    }
    // Remember a prior single-profile tool's EDID solely for exact-match cleanup.
    NSString *legacy=[ep_root() stringByAppendingPathComponent:@"edid.bin"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:legacy]) {
        NSData *data=ep_read_edid(legacy,&error);
        if (!data || !retire(config,data,&error)) return ep_store_error(error);
    }
    return ep_write_config(config,outputPath,&error) ? 0 : ep_store_error(error);
}
