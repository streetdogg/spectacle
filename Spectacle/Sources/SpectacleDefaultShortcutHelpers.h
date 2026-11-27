#import <Foundation/Foundation.h>

#import "SpectacleShortcut.h"

NSArray<SpectacleShortcut *> *SpectacleDefaultShortcutsWithAction(SpectacleShortcutAction action);
SpectacleShortcut *SpectacleDefaultShortcutForNameWithAction(NSString *shortcutName, SpectacleShortcutAction action);
