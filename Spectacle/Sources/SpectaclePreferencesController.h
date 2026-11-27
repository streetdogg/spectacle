#import <Cocoa/Cocoa.h>

#import "SpectacleShortcutRecorderDelegate.h"

@class SpectacleShortcutManager;
@class SpectacleWindowPositionManager;

@protocol SpectacleShortcutStorage;

extern NSString * const SpectacleSettingsTabShortcutsIdentifier;
extern NSString * const SpectacleSettingsTabGeneralIdentifier;
extern NSString * const SpectacleSettingsTabDisabledAppsIdentifier;

@interface SpectaclePreferencesController : NSWindowController <SpectacleShortcutRecorderDelegate, NSToolbarDelegate, NSTableViewDataSource, NSTableViewDelegate>

- (instancetype)initWithShortcutManager:(SpectacleShortcutManager *)shortcutManager
                  windowPositionManager:(SpectacleWindowPositionManager *)windowPositionManager
                        shortcutStorage:(id<SpectacleShortcutStorage>)shortcutStorage;

- (void)selectTabWithIdentifier:(NSString *)identifier animated:(BOOL)animated;

@end
