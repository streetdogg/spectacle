#import "SpectacleLoginItemHelper.h"

#import <ServiceManagement/ServiceManagement.h>

@implementation SpectacleLoginItemHelper

+ (BOOL)isLoginItemEnabledForBundle:(NSBundle *)bundle
{
  if (@available(macOS 13.0, *)) {
    return SMAppService.mainAppService.status == SMAppServiceStatusEnabled;
  }
  return NO;
}

+ (void)enableLoginItemForBundle:(NSBundle *)bundle
{
  if (@available(macOS 13.0, *)) {
    NSError *error = nil;
    if (![SMAppService.mainAppService registerAndReturnError:&error]) {
      NSLog(@"Unable to register the application as a login item: %@", error);
    }
  }
}

+ (void)disableLoginItemForBundle:(NSBundle *)bundle
{
  if (@available(macOS 13.0, *)) {
    NSError *error = nil;
    if (![SMAppService.mainAppService unregisterAndReturnError:&error]) {
      NSLog(@"Unable to unregister the application as a login item: %@", error);
    }
  }
}

@end
