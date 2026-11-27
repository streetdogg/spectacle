#import <Foundation/Foundation.h>

#import "SpectacleShortcutStorageMigrationDestination.h"

@interface SpectacleShortcutJSONStorage : NSObject <SpectacleShortcutStorageMigrationDestination>

+ (NSData *)JSONDataFromShortcuts:(NSArray<SpectacleShortcut *> *)shortcuts error:(NSError **)error;
+ (NSArray<SpectacleShortcut *> *)shortcutsFromJSONData:(NSData *)data
                                                 action:(SpectacleShortcutAction)action
                                                  error:(NSError **)error;

@end
