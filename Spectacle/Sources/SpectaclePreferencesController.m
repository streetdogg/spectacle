#import "SpectaclePreferencesController.h"

#import "SpectacleAccessibilityElement.h"
#import "SpectacleDefaultShortcutHelpers.h"
#import "SpectacleLoginItemHelper.h"
#import "SpectacleRegisteredShortcutValidator.h"
#import "SpectacleShortcut.h"
#import "SpectacleShortcutManager.h"
#import "SpectacleShortcutRecorder.h"
#import "SpectacleShortcutStorage.h"
#import "SpectacleShortcutValidation.h"
#import "SpectacleUtilities.h"
#import "SpectacleWindowPositionManager.h"

static NSArray<NSString *> *leftColumnShortcutNames(void)
{
  return @[
    @"MoveToCenter",
    @"MoveToFullscreen",
    @"MoveToLeftHalf",
    @"MoveToRightHalf",
    @"MoveToTopHalf",
    @"MoveToBottomHalf",
    @"MoveToUpperLeft",
    @"MoveToLowerLeft",
    @"MoveToUpperRight",
    @"MoveToLowerRight",
  ];
}

static NSArray<NSString *> *rightColumnShortcutNames(void)
{
  return @[
    @"MoveToNextDisplay",
    @"MoveToPreviousDisplay",
    @"MoveToNextThird",
    @"MoveToPreviousThird",
    @"MakeLarger",
    @"MakeSmaller",
    @"UndoLastMove",
    @"RedoLastMove",
  ];
}

static NSString *labelForShortcutName(NSString *shortcutName)
{
  static NSDictionary<NSString *, NSString *> *labels;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    labels = @{
      @"MoveToCenter": @"Center:",
      @"MoveToFullscreen": @"Fullscreen:",
      @"MoveToLeftHalf": @"Left Half:",
      @"MoveToRightHalf": @"Right Half:",
      @"MoveToTopHalf": @"Top Half:",
      @"MoveToBottomHalf": @"Bottom Half:",
      @"MoveToUpperLeft": @"Upper Left:",
      @"MoveToLowerLeft": @"Lower Left:",
      @"MoveToUpperRight": @"Upper Right:",
      @"MoveToLowerRight": @"Lower Right:",
      @"MoveToNextDisplay": @"Next Display:",
      @"MoveToPreviousDisplay": @"Previous Display:",
      @"MoveToNextThird": @"Next Third:",
      @"MoveToPreviousThird": @"Previous Third:",
      @"MakeLarger": @"Make Larger:",
      @"MakeSmaller": @"Make Smaller:",
      @"UndoLastMove": @"Undo:",
      @"RedoLastMove": @"Redo:",
    };
  });
  return labels[shortcutName];
}

@implementation SpectaclePreferencesController
{
  SpectacleShortcutManager *_shortcutManager;
  SpectacleWindowPositionManager *_windowPositionManager;
  id<SpectacleShortcutStorage> _shortcutStorage;
  NSDictionary<NSString *, SpectacleShortcutRecorder *> *_shortcutRecorders;
  NSButton *_loginItemCheckbox;
  NSPopUpButton *_statusItemPopup;
}

- (instancetype)initWithShortcutManager:(SpectacleShortcutManager *)shortcutManager
                  windowPositionManager:(SpectacleWindowPositionManager *)windowPositionManager
                        shortcutStorage:(id<SpectacleShortcutStorage>)shortcutStorage
{
  if (self = [super initWithWindow:nil]) {
    _shortcutManager = shortcutManager;
    _windowPositionManager = windowPositionManager;
    _shortcutStorage = shortcutStorage;
    [self buildWindow];
    [self loadRegisteredShortcuts];
  }
  return self;
}

#pragma mark - Window construction

- (void)buildWindow
{
  NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0.0, 0.0, 700.0, 500.0)
                                                 styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                                                   backing:NSBackingStoreBuffered
                                                     defer:NO];
  window.title = [@"Spectacle " stringByAppendingString:SpectacleUtilities.applicationVersion];
  window.releasedWhenClosed = NO;
  window.contentView = [self buildContentView];
  [window center];
  self.window = window;
}

- (NSView *)buildContentView
{
  NSStackView *columns = [NSStackView stackViewWithViews:@[[self buildShortcutColumn:leftColumnShortcutNames()],
                                                          [self buildShortcutColumn:rightColumnShortcutNames()]]];
  columns.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  columns.spacing = 40.0;
  columns.alignment = NSLayoutAttributeTop;

  NSView *footer = [self buildFooterView];

  NSBox *separator = [[NSBox alloc] init];
  separator.boxType = NSBoxSeparator;

  NSStackView *content = [NSStackView stackViewWithViews:@[columns, separator, footer]];
  content.orientation = NSUserInterfaceLayoutOrientationVertical;
  content.spacing = 16.0;
  content.alignment = NSLayoutAttributeLeading;
  content.translatesAutoresizingMaskIntoConstraints = NO;

  NSView *container = [NSView new];
  [container addSubview:content];
  [NSLayoutConstraint activateConstraints:@[
    [content.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:20.0],
    [content.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-20.0],
    [content.topAnchor constraintEqualToAnchor:container.topAnchor constant:20.0],
    [content.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-16.0],
    [separator.widthAnchor constraintEqualToAnchor:content.widthAnchor],
  ]];

  return container;
}

- (NSView *)buildShortcutColumn:(NSArray<NSString *> *)shortcutNames
{
  NSMutableArray<NSView *> *rows = [NSMutableArray new];
  for (NSString *shortcutName in shortcutNames) {
    [rows addObject:[self buildRowForShortcutName:shortcutName]];
  }

  NSStackView *column = [NSStackView stackViewWithViews:rows];
  column.orientation = NSUserInterfaceLayoutOrientationVertical;
  column.spacing = 10.0;
  column.alignment = NSLayoutAttributeLeading;
  return column;
}

- (NSView *)buildRowForShortcutName:(NSString *)shortcutName
{
  NSTextField *label = [NSTextField labelWithString:labelForShortcutName(shortcutName)];
  label.alignment = NSTextAlignmentRight;
  label.translatesAutoresizingMaskIntoConstraints = NO;
  [label.widthAnchor constraintEqualToConstant:130.0].active = YES;

  SpectacleShortcutRecorder *recorder = [SpectacleShortcutRecorder new];
  recorder.translatesAutoresizingMaskIntoConstraints = NO;
  [recorder.widthAnchor constraintEqualToConstant:150.0].active = YES;
  [recorder.heightAnchor constraintEqualToConstant:24.0].active = YES;
  recorder.shortcutName = shortcutName;
  recorder.delegate = self;

  [self storeRecorder:recorder forShortcutName:shortcutName];

  NSStackView *row = [NSStackView stackViewWithViews:@[label, recorder]];
  row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  row.spacing = 8.0;
  row.alignment = NSLayoutAttributeCenterY;
  return row;
}

- (NSView *)buildFooterView
{
  _loginItemCheckbox = [NSButton checkboxWithTitle:@"Launch Spectacle at login"
                                            target:self
                                            action:@selector(toggleLoginItem:)];
  _loginItemCheckbox.state = [SpectacleLoginItemHelper isLoginItemEnabledForBundle:NSBundle.mainBundle]
    ? NSControlStateValueOn
    : NSControlStateValueOff;

  _statusItemPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
  [_statusItemPopup addItemsWithTitles:@[@"Show in menu bar", @"Hide from menu bar"]];
  _statusItemPopup.target = self;
  _statusItemPopup.action = @selector(toggleStatusItem:);
  [_statusItemPopup selectItemAtIndex:[NSUserDefaults.standardUserDefaults boolForKey:@"StatusItemEnabled"] ? 0 : 1];

  NSButton *restoreButton = [NSButton buttonWithTitle:@"Restore Defaults…"
                                               target:self
                                               action:@selector(restoreDefaults:)];

  NSStackView *footer = [NSStackView stackViewWithViews:@[_loginItemCheckbox, _statusItemPopup, restoreButton]];
  footer.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  footer.spacing = 16.0;
  footer.alignment = NSLayoutAttributeCenterY;
  footer.translatesAutoresizingMaskIntoConstraints = NO;
  return footer;
}

- (void)storeRecorder:(SpectacleShortcutRecorder *)recorder forShortcutName:(NSString *)shortcutName
{
  NSMutableDictionary<NSString *, SpectacleShortcutRecorder *> *recorders = [_shortcutRecorders mutableCopy] ?: [NSMutableDictionary new];
  recorders[shortcutName] = recorder;
  _shortcutRecorders = [recorders copy];
}

#pragma mark - Shortcut loading

- (void)loadRegisteredShortcuts
{
  for (NSString *shortcutName in _shortcutRecorders.allKeys) {
    SpectacleShortcutRecorder *recorder = _shortcutRecorders[shortcutName];
    SpectacleShortcut *shortcut = [_shortcutManager shortcutForShortcutName:shortcutName];
    recorder.shortcutName = shortcutName;
    recorder.shortcut = shortcut;
    recorder.delegate = self;
    recorder.shortcutValidation = [[SpectacleShortcutValidation alloc] initWithShortcutManager:_shortcutManager
                                                                                     validators:@[[SpectacleRegisteredShortcutValidator new]]];
  }
}

#pragma mark - SpectacleShortcutRecorderDelegate

- (void)shortcutRecorder:(SpectacleShortcutRecorder *)shortcutRecorder
   didReceiveNewShortcut:(SpectacleShortcut *)shortcut
{
  [_shortcutManager updateShortcut:[shortcut copyWithShortcutAction:^(SpectacleShortcut *updatedShortcut) {
    [self->_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                                      action:updatedShortcut.windowAction];
  }]];
  [self loadRegisteredShortcuts];
}

- (void)shortcutRecorder:(SpectacleShortcutRecorder *)shortcutRecorder
didClearExistingShortcut:(SpectacleShortcut *)shortcut
{
  [_shortcutManager clearShortcut:shortcut];
  [self loadRegisteredShortcuts];
}

#pragma mark - Footer actions

- (IBAction)toggleLoginItem:(id)sender
{
  NSBundle *applicationBundle = NSBundle.mainBundle;
  if (_loginItemCheckbox.state == NSControlStateValueOn) {
    [SpectacleLoginItemHelper enableLoginItemForBundle:applicationBundle];
  } else {
    [SpectacleLoginItemHelper disableLoginItemForBundle:applicationBundle];
  }
}

- (IBAction)toggleStatusItem:(id)sender
{
  BOOL enabled = (_statusItemPopup.indexOfSelectedItem == 0);
  NSString *notificationName = enabled ? @"SpectacleStatusItemEnabledNotification" : @"SpectacleStatusItemDisabledNotification";
  [NSUserDefaults.standardUserDefaults setBool:enabled forKey:@"StatusItemEnabled"];
  [[NSNotificationCenter defaultCenter] postNotificationName:notificationName object:self];
}

- (IBAction)restoreDefaults:(id)sender
{
  [SpectacleUtilities displayRestoreDefaultsAlertWithConfirmationCallback:^{
    NSArray<SpectacleShortcut *> *shortcuts = SpectacleDefaultShortcutsWithAction(^(SpectacleShortcut *shortcut) {
      [self->_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                                        action:shortcut.windowAction];
    });
    [self->_shortcutManager updateShortcuts:shortcuts];
    [self loadRegisteredShortcuts];
  }];
}

@end
