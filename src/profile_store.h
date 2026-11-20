#import <Foundation/Foundation.h>
#include "edid_policy.h"

@interface EPStoredProfile : NSObject
@property(nonatomic,copy) NSString *name;
@property(nonatomic) BOOL enabled;
@property(nonatomic,strong) NSData *factory;
@property(nonatomic,strong) NSData *custom;
@property(nonatomic) EPIdentity identity;
@end

@interface EPConfiguration : NSObject
@property(nonatomic,strong) NSMutableArray<EPStoredProfile *> *profiles;
@property(nonatomic,strong) NSMutableArray<NSData *> *retired;
- (NSArray<NSData *> *)knownOverrides;
@end

NSString *ep_root(void);
NSString *ep_config_path(void);
BOOL ep_name_valid(NSString *name);
NSData *ep_read_edid(NSString *path, NSError **error);
EPStoredProfile *ep_make_profile(NSString *name, NSData *factory, NSData *custom, BOOL enabled, NSError **error);
EPConfiguration *ep_read_config(NSString *path, BOOL allowMissing, NSError **error);
BOOL ep_write_config(EPConfiguration *config, NSString *path, NSError **error);
int ep_list_profiles(void);
int ep_change_profile(NSString *action, NSString *name, NSString *factoryPath, NSString *customPath);
int ep_prepare_config(NSString *defaultsPath, NSString *outputPath);
int ep_store_error(NSError *error);
