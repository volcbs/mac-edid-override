// Multi-profile adaptation of kdotc2/mac-edid-override. MIT; see LICENSE.
@import Foundation;
@import CoreGraphics;
@import AppKit;
#import "profile_store.h"
#include "maintenance.h"
#include <IOKit/IOKitLib.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

typedef CFTypeRef IOAVServiceRef;
typedef IOAVServiceRef (*CreateFunc)(CFAllocatorRef,io_service_t);
typedef IOReturn (*SetFunc)(IOAVServiceRef,uint32_t,CFDataRef);
typedef IOReturn (*CopyFunc)(IOAVServiceRef,CFDataRef *);
typedef IOReturn (*ReadFunc)(IOAVServiceRef,uint32_t,uint32_t,void *,uint32_t);
static CreateFunc createAV;
static SetFunc setVirtual;
static CopyFunc copyEDID;
static ReadFunc readI2C;
static void *iokitHandle;
static NSMutableDictionary<NSNumber *,NSData *> *owned;
static NSMutableSet<NSData *> *remembered;
static NSMutableDictionary<NSNumber *,NSData *> *cleared;
static NSMutableDictionary<NSNumber *,id> *lastPrefixes;
static NSString *lastError;
static dispatch_source_t maintenanceTimer;
static dispatch_source_t displayEvents;
static EPMaintenance maintenance;

@interface EPDisplay : NSObject
@property(nonatomic) IOAVServiceRef service;
@property(nonatomic) uint64_t registryID;
@property(nonatomic) EPIdentity identity;
@property(nonatomic,strong) NSData *physicalPrefix;
@end
@implementation EPDisplay
- (void)dealloc { if (_service) CFRelease(_service); }
@end

static BOOL initHardware(BOOL needsPhysical) {
    if (!iokitHandle) iokitHandle=dlopen("/System/Library/Frameworks/IOKit.framework/IOKit",RTLD_NOW);
    if (!iokitHandle) return NO;
    createAV=(CreateFunc)dlsym(iokitHandle,"IOAVServiceCreateWithService");
    setVirtual=(SetFunc)dlsym(iokitHandle,"IOAVServiceSetVirtualEDIDMode");
    copyEDID=(CopyFunc)dlsym(iokitHandle,"IOAVServiceCopyEDID");
    readI2C=(ReadFunc)dlsym(iokitHandle,"IOAVServiceReadI2C");
    if (!createAV || !setVirtual || !copyEDID || (needsPhysical && !readI2C)) {
        fprintf(stderr,"Required Apple Silicon display APIs are unavailable.\n"); return NO;
    }
    return YES;
}

static BOOL external(io_service_t service) {
    CFTypeRef value=IORegistryEntryCreateCFProperty(service,CFSTR("Location"),kCFAllocatorDefault,0);
    BOOL yes=value && CFGetTypeID(value)==CFStringGetTypeID() &&
        CFStringCompare((CFStringRef)value,CFSTR("External"),0)==kCFCompareEqualTo;
    if (value) CFRelease(value);
    return yes;
}

static BOOL readBlock(IOAVServiceRef service,uint32_t offset,uint8_t *bytes) {
    static const uint8_t header[]={0,255,255,255,255,255,255,0};
    if (!readI2C) return NO;
    memset(bytes,0,128);
    if (readI2C(service,0x50,offset,bytes,128)==kIOReturnSuccess && ep_block_valid(bytes,128) &&
        (offset || !memcmp(bytes,header,8))) return YES;
    memset(bytes,0,128);
    for (uint32_t i=0; i<128; i+=16)
        if (readI2C(service,0x50,offset+i,bytes+i,16)!=kIOReturnSuccess) return NO;
    return ep_block_valid(bytes,128) && (offset || !memcmp(bytes,header,8));
}

// Only physical I2C EDID is identity evidence. CopyEDID may contain an override.
static NSData *physicalPrefix(IOAVServiceRef service,EPIdentity *identity) {
    uint8_t bytes[256]={0};
    memset(identity,0,sizeof(*identity));
    if (!readBlock(service,0,bytes)) return nil;
    size_t length=128;
    if (bytes[126] && readBlock(service,128,bytes+128)) length=256;
    if (!ep_identity(bytes,length,true,identity)) { memset(identity,0,sizeof(*identity)); return nil; }
    return [NSData dataWithBytes:bytes length:length];
}

static NSData *currentEDID(IOAVServiceRef service) {
    CFDataRef data=NULL;
    IOReturn r=copyEDID(service,&data);
    NSData *result=(r==kIOReturnSuccess && data) ? [(__bridge NSData *)data copy] : nil;
    if (data) CFRelease(data);
    return result;
}

static NSArray<EPDisplay *> *displays(BOOL readPhysical) {
    io_iterator_t iterator=IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching("DCPAVServiceProxy"),&iterator)!=kIOReturnSuccess) {
        if (iterator!=IO_OBJECT_NULL) IOObjectRelease(iterator);
        fprintf(stderr,"Could not enumerate display services.\n"); return nil;
    }
    NSMutableArray *results=[NSMutableArray array];
    io_service_t entry;
    while ((entry=IOIteratorNext(iterator))!=IO_OBJECT_NULL) {
        if (!external(entry)) { IOObjectRelease(entry); continue; }
        uint64_t registryID=0;
        if (IORegistryEntryGetRegistryEntryID(entry,&registryID)!=kIOReturnSuccess) { IOObjectRelease(entry); continue; }
        IOAVServiceRef service=createAV(kCFAllocatorDefault,entry);
        IOObjectRelease(entry);
        if (!service) continue;
        if (results.count>=EP_MAX_DISPLAYS) {
            CFRelease(service); IOObjectRelease(iterator);
            fprintf(stderr,"Display-service limit exceeded. No plan will be applied.\n"); return nil;
        }
        EPDisplay *d=[[EPDisplay alloc] init];
        d.service=service; d.registryID=registryID;
        if (readPhysical) {
            EPIdentity identity;
            d.physicalPrefix=physicalPrefix(service,&identity); d.identity=identity;
        }
        [results addObject:d];
    }
    IOObjectRelease(iterator);
    return results;
}

static BOOL makePlan(EPConfiguration *config,NSArray<EPDisplay *> *screens,int *plan) {
    EPProfile profiles[EP_MAX_PROFILES]={0};
    EPIdentity identities[EP_MAX_DISPLAYS]={0};
    if (config.profiles.count>EP_MAX_PROFILES || screens.count>EP_MAX_DISPLAYS) return NO;
    for (NSUInteger i=0; i<config.profiles.count; ++i) {
        profiles[i].identity=config.profiles[i].identity; profiles[i].enabled=config.profiles[i].enabled;
    }
    for (NSUInteger i=0; i<screens.count; ++i) identities[i]=screens[i].identity;
    return ep_plan(profiles,config.profiles.count,identities,screens.count,plan);
}

static void rememberConfig(EPConfiguration *config) {
    if (!config) return;
    // Rebuild rather than accumulating every configuration ever loaded.
    // The persisted config bounds current/history payloads; ownership adds at
    // most one old payload per connected service for pending cleanup.
    NSMutableSet<NSData *> *next=[NSMutableSet setWithArray:config.knownOverrides];
    [next addObjectsFromArray:owned.allValues];
    remembered=next;
}

static BOOL clearOurs(EPDisplay *d) {
    NSData *current=currentEDID(d.service);
    if (!current) return NO;
    NSNumber *key=@(d.registryID);
    if ([remembered containsObject:current] || [owned[key] isEqualToData:current]) {
        // If a custom payload also equals the factory payload, a successful
        // reset does not change readback bytes. Do not reset it every five seconds.
        if ([cleared[key] isEqualToData:current]) { [owned removeObjectForKey:key]; return YES; }
        IOReturn r=setVirtual(d.service,0,NULL);
        if (r!=kIOReturnSuccess) {
            fprintf(stderr,"Could not clear our previous override on service %llu (0x%x).\n",
                (unsigned long long)d.registryID,r); return NO;
        }
        NSData *after=currentEDID(d.service);
        if (after) cleared[key]=after;
        printf("Cleared our previous override on service %llu.\n",(unsigned long long)d.registryID);
    } else [cleared removeObjectForKey:key];
    [owned removeObjectForKey:key];
    return YES;
}

static BOOL stillMatches(EPDisplay *d,EPStoredProfile *p) {
    EPIdentity physical,expected=p.identity;
    if (!physicalPrefix(d.service,&physical)) return NO;
    return ep_matches(&expected,&physical);
}

static BOOL applyOne(EPDisplay *d,EPStoredProfile *p) {
    NSNumber *key=@(d.registryID);
    NSData *current=currentEDID(d.service);
    if (!current) return NO;
    if ([current isEqualToData:p.custom]) { [cleared removeObjectForKey:key]; owned[key]=p.custom; return YES; }
    if (!stillMatches(d,p)) return clearOurs(d);
    IOReturn r=setVirtual(d.service,0,NULL);
    if (r!=kIOReturnSuccess) return NO;
    usleep(500000);
    if (!stillMatches(d,p)) return clearOurs(d);
    r=setVirtual(d.service,1,(__bridge CFDataRef)p.custom);
    if (r!=kIOReturnSuccess) {
        fprintf(stderr,"Applying '%s' failed (0x%x).\n",p.name.UTF8String,r); return NO;
    }
    owned[key]=p.custom;
    [cleared removeObjectForKey:key];
    NSData *readback=currentEDID(d.service);
    if (![readback isEqualToData:p.custom]) {
        fprintf(stderr,"Readback failed for '%s'; attempting to clear this override.\n",p.name.UTF8String);
        (void)clearOurs(d); return NO;
    }
    printf("Applied '%s' to service %llu.\n",p.name.UTF8String,(unsigned long long)d.registryID);
    return YES;
}

static int reconcile(void) {
    NSError *error=nil;
    EPConfiguration *config=ep_read_config(ep_config_path(),NO,&error);
    if (!config) {
        NSString *message=error.localizedDescription ?: @"Invalid profile configuration.";
        if (![lastError isEqualToString:message]) fprintf(stderr,"%s No new overrides will be applied.\n",message.UTF8String);
        lastError=message;
        config=[[EPConfiguration alloc] init]; // Known old overrides can still be cleared.
    } else {
        lastError=nil;
        rememberConfig(config);
    }
    NSArray<EPDisplay *> *screens=displays(YES);
    if (!screens) return 1;
    int plan[EP_MAX_DISPLAYS];
    if (!makePlan(config,screens,plan)) return 1;
    BOOL okay=YES;
    NSMutableSet<NSNumber *> *seen=[NSMutableSet set];
    for (NSUInteger i=0; i<screens.count; ++i) {
        EPDisplay *d=screens[i]; NSNumber *key=@(d.registryID); [seen addObject:key];
        id prefix=d.physicalPrefix ?: (id)[NSNull null];
        if (lastPrefixes[key] && ![lastPrefixes[key] isEqual:prefix]) [cleared removeObjectForKey:key];
        lastPrefixes[key]=prefix;
        if (plan[i]>=0) okay=applyOne(d,config.profiles[(NSUInteger)plan[i]]) && okay;
        else okay=clearOurs(d) && okay;
    }
    for (NSNumber *key in [owned.allKeys copy])
        if (![seen containsObject:key]) [owned removeObjectForKey:key];
    for (NSNumber *key in [lastPrefixes.allKeys copy])
        if (![seen containsObject:key]) { [lastPrefixes removeObjectForKey:key]; [cleared removeObjectForKey:key]; }
    return okay && !lastError ? 0 : 1;
}

static int inspect(NSString *path,BOOL requireMatch) {
    NSError *error=nil;
    EPConfiguration *config=ep_read_config(path,NO,&error);
    if (!config) return ep_store_error(error);
    NSArray<EPDisplay *> *screens=displays(YES);
    if (!screens) return 1;
    int plan[EP_MAX_DISPLAYS];
    if (!makePlan(config,screens,plan)) return 1;
    printf("Profiles: %lu; external display services: %lu.\n",(unsigned long)config.profiles.count,(unsigned long)screens.count);
    NSUInteger eligible=0;
    for (NSUInteger i=0; i<screens.count; ++i) {
        EPDisplay *d=screens[i]; EPIdentity identity=d.identity;
        printf("Service %llu: ",(unsigned long long)d.registryID);
        if (!identity.verified) { printf("SKIPPED: physical identity unreadable.\n"); continue; }
        printf("vendor=%04X product=%04X numeric=%u text=%s; ",identity.vendor,identity.product,
            identity.numeric_serial,identity.has_text ? identity.text_serial : "(none)");
        if (plan[i]==EP_AMBIGUOUS) printf("SKIPPED: ambiguous identity/profile match.\n");
        else if (plan[i]==EP_NONE) printf("SKIPPED: no enabled matching profile.\n");
        else {
            ++eligible;
            EPStoredProfile *p=config.profiles[(NSUInteger)plan[i]];
            BOOL active=[currentEDID(d.service) isEqualToData:p.custom];
            printf("VERIFIED '%s'; %s.\n",p.name.UTF8String,active ? "ACTIVE" : "not active");
        }
    }
    if (requireMatch && !eligible) { printf("No uniquely verified enabled profile is connected.\n"); return 2; }
    return 0;
}

static int clearConfig(NSString *path) {
    NSError *error=nil;
    EPConfiguration *config=ep_read_config(path,NO,&error);
    if (!config) return ep_store_error(error);
    rememberConfig(config);
    NSArray<EPDisplay *> *screens=displays(NO);
    if (!screens) return 1;
    BOOL okay=YES;
    for (EPDisplay *d in screens) okay=clearOurs(d) && okay;
    return okay ? 0 : 1;
}

static NSString *agentPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/LaunchAgents/com.edid-override.plist"];
}
static NSString *domain(void) { return [NSString stringWithFormat:@"gui/%u",(unsigned)getuid()]; }
static NSString *job(void) { return [domain() stringByAppendingString:@"/com.edid-override"]; }
static int runTask(NSString *binary,NSArray<NSString *> *args) {
    NSTask *task=[[NSTask alloc] init]; task.executableURL=[NSURL fileURLWithPath:binary]; task.arguments=args;
    task.standardOutput=[NSFileHandle fileHandleWithNullDevice]; task.standardError=[NSFileHandle fileHandleWithNullDevice];
    NSError *error=nil;
    if (![task launchAndReturnError:&error]) return 1;
    [task waitUntilExit]; return task.terminationStatus;
}
static int launchctl(NSArray<NSString *> *args) { return runTask(@"/bin/launchctl",args); }
static BOOL standardRoot(void) {
    NSString *expected=[NSHomeDirectory() stringByAppendingPathComponent:@".config/edid-override"];
    if (![ep_root() isEqualToString:expected]) {
        fprintf(stderr,"Startup commands require the standard installation directory. Unset EDID_OVERRIDE_ROOT.\n"); return NO;
    }
    return YES;
}

static int enableJob(void) {
    if (!standardRoot()) return 1;
    NSError *error=nil;
    if (!ep_read_config(ep_config_path(),NO,&error)) return ep_store_error(error);
    NSString *binary=[ep_root() stringByAppendingPathComponent:@"edid_override"];
    if (runTask(binary,@[@"--version"])!=0) { fprintf(stderr,"Install the multi-profile binary first.\n"); return 1; }
    NSDictionary *plist=@{@"Label":@"com.edid-override",@"ProgramArguments":@[binary,@"--daemon"],
        @"RunAtLoad":@YES,@"KeepAlive":@YES,@"Umask":@63,
        @"StandardOutPath":[ep_root() stringByAppendingPathComponent:@"edid-override.log"],
        @"StandardErrorPath":[ep_root() stringByAppendingPathComponent:@"edid-override.log"]};
    NSData *xml=[NSPropertyListSerialization dataWithPropertyList:plist format:NSPropertyListXMLFormat_v1_0 options:0 error:&error];
    if (![[NSFileManager defaultManager] createDirectoryAtPath:[agentPath() stringByDeletingLastPathComponent]
        withIntermediateDirectories:YES attributes:nil error:&error] || !xml ||
        ![xml writeToFile:agentPath() options:NSDataWritingAtomic error:&error] ||
        ![[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions:@0600}
            ofItemAtPath:agentPath() error:&error]) return ep_store_error(error);
    if (launchctl(@[@"enable",job()])!=0) return 1;
    if (launchctl(@[@"print",job()])!=0 && launchctl(@[@"bootstrap",domain(),agentPath()])!=0) return 1;
    printf("Multi-profile background process enabled. Profiles reload automatically.\n"); return 0;
}

static int resetJob(void) {
    if (!standardRoot()) return 1;
    if (launchctl(@[@"disable",job()])!=0) return 1;
    (void)launchctl(@[@"bootout",job()]);
    if (launchctl(@[@"print",job()])==0) { fprintf(stderr,"Background job is still loaded.\n"); return 1; }
    if (!initHardware(NO)) { fprintf(stderr,"Job disabled. Reconnect displays to clear any remaining virtual EDID.\n"); return 1; }
    int result=clearConfig(ep_config_path());
    if (!result) printf("Known overrides cleared; startup disabled until --enable. Profiles retained.\n");
    return result;
}

static uint64_t monotonicNow(void) {
    struct timespec now={0};
    if (clock_gettime(CLOCK_MONOTONIC,&now)!=0)
        return (uint64_t)(NSProcessInfo.processInfo.systemUptime*(double)EP_POLL_SECOND);
    return (uint64_t)now.tv_sec*EP_POLL_SECOND+(uint64_t)now.tv_nsec;
}
static void armMaintenance(void) {
    uint64_t delay=ep_poll_delay(&maintenance,monotonicNow());
    dispatch_source_set_timer(maintenanceTimer,dispatch_time(DISPATCH_TIME_NOW,(int64_t)delay),
        DISPATCH_TIME_FOREVER,100*NSEC_PER_MSEC);
}
static void requestMaintenance(void) {
    // DATA_OR keeps a single coalesced pending event even during an event storm.
    if (displayEvents) dispatch_source_merge_data(displayEvents,1);
}
static void reconfigured(CGDirectDisplayID display,CGDisplayChangeSummaryFlags flags,void *context) {
    (void)display; (void)context;
    if (flags & kCGDisplayBeginConfigurationFlag) return;
    requestMaintenance();
}
@interface EPWakeObserver : NSObject
- (void)woke:(NSNotification *)notification;
@end
@implementation EPWakeObserver
- (void)woke:(NSNotification *)notification { (void)notification; requestMaintenance(); }
@end
static int runDaemon(void) {
    // Drain the initial scan instead of retaining its autoreleased objects in
    // main's lifetime-long autorelease pool.
    @autoreleasepool { (void)reconcile(); }
    ep_poll_init(&maintenance,monotonicNow());
    maintenanceTimer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_main_queue());
    displayEvents=dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_OR,0,0,dispatch_get_main_queue());
    if (!maintenanceTimer || !displayEvents) return 1;
    dispatch_source_set_event_handler(maintenanceTimer,^{ @autoreleasepool {
        (void)reconcile();
        ep_poll_finished(&maintenance,monotonicNow());
        armMaintenance();
    } });
    dispatch_source_set_event_handler(displayEvents,^{ @autoreleasepool {
        ep_poll_request(&maintenance,monotonicNow());
        armMaintenance();
    } });
    armMaintenance();
    dispatch_resume(maintenanceTimer); dispatch_resume(displayEvents);
    if (CGDisplayRegisterReconfigurationCallback(reconfigured,NULL)!=kCGErrorSuccess) {
        dispatch_source_cancel(maintenanceTimer); dispatch_source_cancel(displayEvents); return 1;
    }
    EPWakeObserver *observer=[[EPWakeObserver alloc] init];
    NSNotificationCenter *center=NSWorkspace.sharedWorkspace.notificationCenter;
    [center addObserver:observer selector:@selector(woke:) name:NSWorkspaceDidWakeNotification object:nil];
    [center addObserver:observer selector:@selector(woke:) name:NSWorkspaceScreensDidWakeNotification object:nil];
    printf("Monitoring all external displays; unknown/ambiguous identities are skipped.\n");
    // Also drain autoreleased objects that AppKit/Foundation may create around
    // notification delivery, outside our own dispatch handlers.
    BOOL running=YES;
    while (running) {
        @autoreleasepool {
            SInt32 state=CFRunLoopRunInMode(kCFRunLoopDefaultMode,5.0,false);
            running=state!=kCFRunLoopRunFinished && state!=kCFRunLoopRunStopped;
        }
    }
    [center removeObserver:observer];
    CGDisplayRemoveReconfigurationCallback(reconfigured,NULL);
    dispatch_source_cancel(maintenanceTimer); dispatch_source_cancel(displayEvents);
    return 0;
}

static void help(void) {
    puts("EDID Override Profiles 2.1-public\n"
         "  --list                                    List saved profiles\n"
         "  --add NAME FACTORY.bin CUSTOM.bin          Add a profile\n"
         "  --replace NAME FACTORY.bin CUSTOM.bin      Replace a profile\n"
         "  --disable-profile NAME                    Disable one profile\n"
         "  --enable-profile NAME                     Enable one profile\n"
         "  --remove NAME                             Remove a profile\n"
         "  --status / --scan                         Inspect connected displays\n"
         "  --apply                                   Reconcile once\n"
         "  --enable                                  Enable background startup\n"
         "  --reset                                   Disable startup and clear known overrides\n"
         "  --daemon                                  Run the background process\n"
         "  --validate-config FILE                    Validate configuration without display access\n"
         "  --probe-config FILE                       Read-only physical match check\n"
         "  --prepare-config DEFAULTS OUTPUT           Prepare a preserving upgrade\n"
         "  --clear-config FILE                       Clear only this configuration's known overrides");
}

int main(int argc,const char *argv[]) {
    @autoreleasepool {
        setvbuf(stdout,NULL,_IOLBF,0);
        owned=[[NSMutableDictionary alloc] init]; remembered=[[NSMutableSet alloc] init];
        cleared=[[NSMutableDictionary alloc] init]; lastPrefixes=[[NSMutableDictionary alloc] init];
        NSString *command=argc>1 ? [NSString stringWithUTF8String:argv[1]] : @"--help";
        if ([command isEqualToString:@"--help"]) { help(); return 0; }
        if ([command isEqualToString:@"--version"]) { puts("edid-override-profiles 2.1-public"); return 0; }
        if ([command isEqualToString:@"--list"] && argc==2) return ep_list_profiles();
        if (([command isEqualToString:@"--add"] || [command isEqualToString:@"--replace"]) && argc==5)
            return ep_change_profile([command substringFromIndex:2],[NSString stringWithUTF8String:argv[2]],
                [NSString stringWithUTF8String:argv[3]],[NSString stringWithUTF8String:argv[4]]);
        if (([command isEqualToString:@"--remove"] || [command isEqualToString:@"--disable-profile"] ||
             [command isEqualToString:@"--enable-profile"]) && argc==3)
            return ep_change_profile([command substringFromIndex:2],[NSString stringWithUTF8String:argv[2]],nil,nil);
        if ([command isEqualToString:@"--validate-config"] && argc==3) {
            NSError *error=nil;
            return ep_read_config([NSString stringWithUTF8String:argv[2]],NO,&error) ? 0 : ep_store_error(error);
        }
        if ([command isEqualToString:@"--prepare-config"] && argc==4)
            return ep_prepare_config([NSString stringWithUTF8String:argv[2]],[NSString stringWithUTF8String:argv[3]]);
        if ([command isEqualToString:@"--enable"] && argc==2) return enableJob();
        if ([command isEqualToString:@"--reset"] && argc==2) return resetJob();
        BOOL recognized=([command isEqualToString:@"--status"] || [command isEqualToString:@"--scan"] ||
            [command isEqualToString:@"--apply"] || [command isEqualToString:@"--daemon"]) && argc==2;
        recognized=recognized || (([command isEqualToString:@"--probe-config"] || [command isEqualToString:@"--clear-config"]) && argc==3);
        if (!recognized) { help(); return 1; }
        if (!initHardware(![command isEqualToString:@"--clear-config"])) return 1;
        if ([command isEqualToString:@"--status"] || [command isEqualToString:@"--scan"]) return inspect(ep_config_path(),NO);
        if ([command isEqualToString:@"--probe-config"]) return inspect([NSString stringWithUTF8String:argv[2]],YES);
        if ([command isEqualToString:@"--clear-config"]) return clearConfig([NSString stringWithUTF8String:argv[2]]);
        if ([command isEqualToString:@"--apply"]) return reconcile();
        return runDaemon();
    }
}
