#import "SpectacleAppDelegate.h"

#import "SpectacleAccessibilityElement.h"
#import "SpectacleDefaultShortcutHelpers.h"
#import "SpectacleMigratingShortcutStorage.h"
#import "SpectaclePreferencesController.h"
#import "SpectacleScreenDetector.h"
#import "SpectacleShortcutJSONStorage.h"
#import "SpectacleShortcutManager.h"
#import "SpectacleShortcutUserDefaultsStorage.h"
#import "SpectacleUtilities.h"
#import "SpectacleWindowPositionCalculator.h"
#import "SpectacleWindowPositionManager.h"

@implementation SpectacleAppDelegate
{
  NSStatusItem *_statusItem;
  NSMenuItem *_disableShortcutsForAnHourMenuItem;
  NSMenuItem *_disableShortcutsForApplicationMenuItem;
  id<SpectacleShortcutStorage> _shortcutStorage;
  SpectacleShortcutManager *_shortcutManager;
  SpectacleWindowPositionManager *_windowPositionManager;
  SpectaclePreferencesController *_preferencesController;
  NSTimer *_disableShortcutsForAnHourTimer;
  NSSet<NSString *> *_blacklistedApplications;
  NSMutableSet<NSString *> *_disabledApplications;
  BOOL _shortcutsAreDisabledForAnHour;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
  [SpectacleUtilities registerDefaultsForBundle:[NSBundle mainBundle]];

  NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
  _blacklistedApplications = [NSSet setWithArray:[userDefaults objectForKey:@"BlacklistedApplications"]];
  _disabledApplications = [NSMutableSet setWithArray:[userDefaults objectForKey:@"DisabledApplications"]];

  _shortcutStorage = [[SpectacleMigratingShortcutStorage alloc] initWithShortcutStorage:[SpectacleShortcutUserDefaultsStorage new]
                                                                   migrationDestination:[SpectacleShortcutJSONStorage new]];
  _shortcutManager = [[SpectacleShortcutManager alloc] initWithShortcutStorage:_shortcutStorage];

  SpectacleWindowPositionCalculator *windowPositionCalculator = [[SpectacleWindowPositionCalculator alloc] initWithErrorHandler:^(NSString *errorMessage) {
    NSAlert *alert = [NSAlert new];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = @"Encountered an unexpected error";
    alert.informativeText = errorMessage;
    [alert runModal];
  }];

  _windowPositionManager = [[SpectacleWindowPositionManager alloc] initWithScreenDetector:[SpectacleScreenDetector new]
                                                                 windowPositionCalculator:windowPositionCalculator
                                                                          sharedWorkspace:[NSWorkspace sharedWorkspace]];

  _preferencesController = [[SpectaclePreferencesController alloc] initWithShortcutManager:_shortcutManager
                                                                     windowPositionManager:_windowPositionManager
                                                                           shortcutStorage:_shortcutStorage];

  _shortcutsAreDisabledForAnHour = NO;

  [self observeNotifications];

  if ([userDefaults boolForKey:@"StatusItemEnabled"]) {
    [self enableStatusItem];
  }

  [self manageShortcuts];
  [self disableShortcutsIfFrontmostApplicationIsBlacklistedOrDisabled];

  if (!AXIsProcessTrustedWithOptions(NULL)) {
    [self displayAccessibilityPrompt];
  }
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [[NSWorkspace sharedWorkspace].notificationCenter removeObserver:self];
}

#pragma mark - Status item

- (void)enableStatusItem
{
  if (_statusItem) {
    return;
  }
  _statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
  NSImage *statusImage = [NSBundle.mainBundle imageForResource:@"Spectacle Status Item"];
  statusImage.template = YES;
  _statusItem.button.image = statusImage;
  _statusItem.button.toolTip = [@"Spectacle " stringByAppendingString:SpectacleUtilities.applicationVersion];
  _statusItem.menu = [self statusMenu];
}

- (void)disableStatusItem
{
  if (_statusItem) {
    [[NSStatusBar systemStatusBar] removeStatusItem:_statusItem];
    _statusItem = nil;
  }
}

- (NSMenu *)statusMenu
{
  NSMenu *menu = [NSMenu new];
  menu.delegate = self;

  NSMenuItem *aboutItem = [[NSMenuItem alloc] initWithTitle:@"About Spectacle"
                                                     action:@selector(showAboutPanel:)
                                              keyEquivalent:@""];
  aboutItem.target = self;
  [menu addItem:aboutItem];

  [menu addItem:[NSMenuItem separatorItem]];

  NSMenuItem *preferencesItem = [[NSMenuItem alloc] initWithTitle:@"Preferences…"
                                                           action:@selector(showPreferencesWindow:)
                                                    keyEquivalent:@","];
  preferencesItem.target = self;
  [menu addItem:preferencesItem];

  [menu addItem:[NSMenuItem separatorItem]];

  NSMenuItem *disableItem = [[NSMenuItem alloc] initWithTitle:@"Disable Shortcuts" action:nil keyEquivalent:@""];
  NSMenu *disableMenu = [NSMenu new];
  disableMenu.autoenablesItems = NO;
  _disableShortcutsForAnHourMenuItem = [[NSMenuItem alloc] initWithTitle:@"For an Hour"
                                                                  action:@selector(disableOrEnableShortcutsForAnHour:)
                                                           keyEquivalent:@""];
  _disableShortcutsForAnHourMenuItem.target = self;
  [disableMenu addItem:_disableShortcutsForAnHourMenuItem];
  _disableShortcutsForApplicationMenuItem = [[NSMenuItem alloc] initWithTitle:@"For the Current Application"
                                                                       action:@selector(disableOrEnableShortcutsForApplication:)
                                                                keyEquivalent:@""];
  _disableShortcutsForApplicationMenuItem.target = self;
  [disableMenu addItem:_disableShortcutsForApplicationMenuItem];
  disableItem.submenu = disableMenu;
  [menu addItem:disableItem];

  [menu addItem:[NSMenuItem separatorItem]];

  NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit Spectacle"
                                                    action:@selector(terminate:)
                                             keyEquivalent:@"q"];
  quitItem.target = NSApp;
  [menu addItem:quitItem];

  return menu;
}

#pragma mark - NSMenuDelegate

- (void)menuWillOpen:(NSMenu *)menu
{
  _disableShortcutsForAnHourMenuItem.state = _shortcutsAreDisabledForAnHour
    ? NSControlStateValueOn
    : NSControlStateValueOff;

  NSRunningApplication *frontmostApplication = [NSWorkspace sharedWorkspace].frontmostApplication;
  NSString *bundleIdentifier = frontmostApplication.bundleIdentifier;
  if (!bundleIdentifier || [_blacklistedApplications containsObject:bundleIdentifier]) {
    _disableShortcutsForApplicationMenuItem.title = @"For the Current Application";
    _disableShortcutsForApplicationMenuItem.state = NSControlStateValueOff;
    _disableShortcutsForApplicationMenuItem.enabled = NO;
  } else {
    NSString *applicationName = frontmostApplication.localizedName ?: @"the Current Application";
    _disableShortcutsForApplicationMenuItem.title = [NSString stringWithFormat:@"For %@", applicationName];
    _disableShortcutsForApplicationMenuItem.state = [_disabledApplications containsObject:bundleIdentifier]
      ? NSControlStateValueOn
      : NSControlStateValueOff;
    _disableShortcutsForApplicationMenuItem.enabled = YES;
  }
}

#pragma mark - Shortcut management

- (void)manageShortcuts
{
  SpectacleShortcutAction action = ^(SpectacleShortcut *shortcut) {
    [self->_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                                      action:shortcut.windowAction];
  };

  NSArray<SpectacleShortcut *> *shortcuts = [_shortcutStorage loadShortcutsWithAction:action];
  if (shortcuts.count != 0) {
    [_shortcutManager manageShortcuts:shortcuts];
  } else {
    [_shortcutManager manageShortcuts:SpectacleDefaultShortcutsWithAction(action)];
  }
}

- (void)enableShortcutsIfPermittedForApplication:(NSRunningApplication *)application
{
  if (_shortcutsAreDisabledForAnHour) {
    return;
  }

  NSString *bundleIdentifier = application.bundleIdentifier;
  if (bundleIdentifier
      && ([_blacklistedApplications containsObject:bundleIdentifier]
          || [_disabledApplications containsObject:bundleIdentifier])) {
    return;
  }

  [_shortcutManager registerShortcuts];
}

- (void)enableShortcutsIfPermitted
{
  [self enableShortcutsIfPermittedForApplication:[NSWorkspace sharedWorkspace].frontmostApplication];
}

- (void)disableShortcutsIfFrontmostApplicationIsBlacklistedOrDisabled
{
  NSRunningApplication *frontmostApplication = [NSWorkspace sharedWorkspace].frontmostApplication;
  if (![_blacklistedApplications containsObject:frontmostApplication.bundleIdentifier]
      && ![_disabledApplications containsObject:frontmostApplication.bundleIdentifier]) {
    return;
  }
  [_shortcutManager unregisterShortcuts];
}

- (IBAction)disableOrEnableShortcutsForAnHour:(id)sender
{
  if (_shortcutsAreDisabledForAnHour) {
    _shortcutsAreDisabledForAnHour = NO;
    [_disableShortcutsForAnHourTimer invalidate];
    _disableShortcutsForAnHourTimer = nil;
    [self enableShortcutsIfPermitted];
  } else {
    _shortcutsAreDisabledForAnHour = YES;
    _disableShortcutsForAnHourTimer = [NSTimer scheduledTimerWithTimeInterval:3600
                                                                       target:self
                                                                     selector:@selector(disableOrEnableShortcutsForAnHour:)
                                                                     userInfo:nil
                                                                      repeats:NO];
    [_shortcutManager unregisterShortcuts];
  }
}

- (IBAction)disableOrEnableShortcutsForApplication:(id)sender
{
  NSRunningApplication *frontmostApplication = [NSWorkspace sharedWorkspace].frontmostApplication;
  NSString *bundleIdentifier = frontmostApplication.bundleIdentifier;
  if (!bundleIdentifier) {
    return;
  }
  if ([_disabledApplications containsObject:bundleIdentifier]) {
    [_disabledApplications removeObject:bundleIdentifier];
    [self enableShortcutsIfPermitted];
  } else {
    [_disabledApplications addObject:bundleIdentifier];
    [_shortcutManager unregisterShortcuts];
  }
  [NSUserDefaults.standardUserDefaults setObject:_disabledApplications.allObjects forKey:@"DisabledApplications"];
}

#pragma mark - Actions

- (void)activateApplication
{
  if (@available(macOS 14.0, *)) {
    [NSApp activate];
  } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [NSApp activateIgnoringOtherApps:YES];
#pragma clang diagnostic pop
  }
}

- (IBAction)showAboutPanel:(id)sender
{
  [self activateApplication];
  [NSApp orderFrontStandardAboutPanel:sender];
}

- (IBAction)showPreferencesWindow:(id)sender
{
  [self activateApplication];
  [_preferencesController showWindow:sender];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)application hasVisibleWindows:(BOOL)visibleWindows
{
  [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"StatusItemEnabled"];
  [self enableStatusItem];
  return YES;
}

#pragma mark - Accessibility

- (void)displayAccessibilityPrompt
{
  [self activateApplication];
  NSAlert *alert = [NSAlert new];
  alert.alertStyle = NSAlertStyleWarning;
  alert.messageText = @"Spectacle requires Accessibility access";
  alert.informativeText = @"Spectacle needs permission to control your computer through Accessibility. In System Settings open Privacy & Security → Accessibility (search for \"Accessibility\" if you don't see it), enable Spectacle, then relaunch.";
  [alert addButtonWithTitle:@"Open System Settings"];
  [alert addButtonWithTitle:@"Quit"];

  NSModalResponse response = [alert runModal];
  if (response == NSAlertFirstButtonReturn) {
    NSURL *url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"];
    [[NSWorkspace sharedWorkspace] openURL:url];
  } else {
    [NSApp terminate:nil];
  }
}

#pragma mark - Workspace notifications

- (void)observeWorkspaceNotifications
{
  [[NSWorkspace sharedWorkspace].notificationCenter addObserver:self
                                                       selector:@selector(applicationDidActivate:)
                                                           name:NSWorkspaceDidActivateApplicationNotification
                                                         object:nil];
  [[NSWorkspace sharedWorkspace].notificationCenter addObserver:self
                                                       selector:@selector(applicationDidDeactivate:)
                                                           name:NSWorkspaceDidDeactivateApplicationNotification
                                                         object:nil];
}

- (void)observeNotifications
{
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(enableStatusItem)
                                               name:@"SpectacleStatusItemEnabledNotification"
                                             object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(disableStatusItem)
                                               name:@"SpectacleStatusItemDisabledNotification"
                                             object:nil];
  [self observeWorkspaceNotifications];
}

- (void)applicationDidActivate:(NSNotification *)notification
{
  NSRunningApplication *application = notification.userInfo[NSWorkspaceApplicationKey];
  NSString *bundleIdentifier = application.bundleIdentifier;
  if (bundleIdentifier
      && ([_blacklistedApplications containsObject:bundleIdentifier]
          || [_disabledApplications containsObject:bundleIdentifier])) {
    [_shortcutManager unregisterShortcuts];
  } else {
    [self enableShortcutsIfPermittedForApplication:application];
  }
}

- (void)applicationDidDeactivate:(NSNotification *)notification
{
  NSRunningApplication *application = notification.userInfo[NSWorkspaceApplicationKey];
  if ([_blacklistedApplications containsObject:application.bundleIdentifier]
      || [_disabledApplications containsObject:application.bundleIdentifier]) {
    [self enableShortcutsIfPermitted];
  }
}

@end
