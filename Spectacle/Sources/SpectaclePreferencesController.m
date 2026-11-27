#import "SpectaclePreferencesController.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "SpectacleAccessibilityElement.h"
#import "SpectacleDefaultShortcutHelpers.h"
#import "SpectacleLoginItemHelper.h"
#import "SpectacleRegisteredShortcutValidator.h"
#import "SpectacleShortcut.h"
#import "SpectacleShortcutJSONStorage.h"
#import "SpectacleShortcutManager.h"
#import "SpectacleShortcutRecorder.h"
#import "SpectacleShortcutStorage.h"
#import "SpectacleShortcutValidation.h"
#import "SpectacleUpdateController.h"
#import "SpectacleUtilities.h"
#import "SpectacleWindowPositionManager.h"

NSString * const SpectacleSettingsTabShortcutsIdentifier = @"Shortcuts";
NSString * const SpectacleSettingsTabGeneralIdentifier = @"General";
NSString * const SpectacleSettingsTabDisabledAppsIdentifier = @"DisabledApps";

static NSString * const SpectacleDisabledApplicationsDidChangeNotification = @"SpectacleDisabledApplicationsDidChangeNotification";
static NSString * const SpectacleToolbarTabSwitcherIdentifier = @"SpectacleTabSwitcher";

#pragma mark - Card Container View

@interface SpectacleCardView : NSView
@property (nonatomic, strong) NSColor *cardFillColor;
@property (nonatomic, strong) NSColor *cardBorderColor;
@property (nonatomic, assign) CGFloat cardBorderWidth;
@property (nonatomic, assign) CGFloat cardCornerRadius;
@end

@implementation SpectacleCardView

- (instancetype)initWithFrame:(NSRect)frameRect
{
  if (self = [super initWithFrame:frameRect]) {
    self.wantsLayer = YES;
    _cardCornerRadius = 12.0;
    _cardBorderWidth = 0.5;
    _cardBorderColor = [NSColor colorWithName:@"SpectacleCardBorder" dynamicProvider:^NSColor *(NSAppearance *appearance) {
      NSAppearanceName best = [appearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameDarkAqua, NSAppearanceNameAqua]];
      if ([best isEqualToString:NSAppearanceNameDarkAqua]) {
        return [[NSColor whiteColor] colorWithAlphaComponent:0.10];
      }
      return [[NSColor blackColor] colorWithAlphaComponent:0.08];
    }];
    _cardFillColor = [NSColor colorWithName:@"SpectacleCardFill" dynamicProvider:^NSColor *(NSAppearance *appearance) {
      NSAppearanceName best = [appearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameDarkAqua, NSAppearanceNameAqua]];
      if ([best isEqualToString:NSAppearanceNameDarkAqua]) {
        return [[NSColor whiteColor] colorWithAlphaComponent:0.055];
      }
      return [[NSColor whiteColor] colorWithAlphaComponent:0.72];
    }];
    [self updateLayerAppearance];
  }
  return self;
}

- (void)viewDidChangeEffectiveAppearance
{
  [super viewDidChangeEffectiveAppearance];
  [self updateLayerAppearance];
}

- (void)updateLayerAppearance
{
  [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
    self.layer.cornerRadius = self->_cardCornerRadius;
    self.layer.borderWidth = self->_cardBorderWidth;
    self.layer.borderColor = self->_cardBorderColor.CGColor;
    self.layer.backgroundColor = self->_cardFillColor.CGColor;
  }];
}

@end

#pragma mark - Disabled App Entry Model

@interface SpectacleAppListEntry : NSObject
@property (nonatomic, copy) NSString *bundleIdentifier;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, strong) NSImage *icon;
@property (nonatomic, assign) BOOL isBuiltIn;
@end

@implementation SpectacleAppListEntry
@end

#pragma mark - Shortcut Metadata Helpers

static NSString *localizedLabelForShortcutName(NSString *shortcutName)
{
  static NSDictionary<NSString *, NSString *> *keys;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    keys = @{
      @"MoveToCenter": @"ShortcutLabelMoveToCenter",
      @"MoveToFullscreen": @"ShortcutLabelMoveToFullscreen",
      @"MoveToLeftHalf": @"ShortcutLabelMoveToLeftHalf",
      @"MoveToRightHalf": @"ShortcutLabelMoveToRightHalf",
      @"MoveToTopHalf": @"ShortcutLabelMoveToTopHalf",
      @"MoveToBottomHalf": @"ShortcutLabelMoveToBottomHalf",
      @"MoveToUpperLeft": @"ShortcutLabelMoveToUpperLeft",
      @"MoveToLowerLeft": @"ShortcutLabelMoveToLowerLeft",
      @"MoveToUpperRight": @"ShortcutLabelMoveToUpperRight",
      @"MoveToLowerRight": @"ShortcutLabelMoveToLowerRight",
      @"MoveToNextDisplay": @"ShortcutLabelMoveToNextDisplay",
      @"MoveToPreviousDisplay": @"ShortcutLabelMoveToPreviousDisplay",
      @"MoveToNextThird": @"ShortcutLabelMoveToNextThird",
      @"MoveToPreviousThird": @"ShortcutLabelMoveToPreviousThird",
      @"MakeLarger": @"ShortcutLabelMakeLarger",
      @"MakeSmaller": @"ShortcutLabelMakeSmaller",
      @"UndoLastMove": @"ShortcutLabelUndoLastMove",
      @"RedoLastMove": @"ShortcutLabelRedoLastMove",
    };
  });
  NSString *key = keys[shortcutName];
  return key ? NSLocalizedString(key, @"Shortcut action label") : shortcutName;
}

static NSImage *schematicIconWithFilledRect(NSRect (^fillRectBlock)(NSRect inner))
{
  NSImage *image = [NSImage imageWithSize:NSMakeSize(18.0, 14.0) flipped:NO drawingHandler:^BOOL(NSRect dstRect) {
    NSRect frameRect = NSMakeRect(1.0, 1.0, 16.0, 12.0);
    NSBezierPath *framePath = [NSBezierPath bezierPathWithRoundedRect:frameRect xRadius:2.2 yRadius:2.2];
    framePath.lineWidth = 1.2;
    [[NSColor blackColor] setStroke];
    [framePath stroke];

    NSRect inner = NSMakeRect(2.75, 2.75, 12.5, 8.5);
    NSRect fillRect = fillRectBlock(inner);
    NSBezierPath *fillPath = [NSBezierPath bezierPathWithRoundedRect:fillRect xRadius:1.0 yRadius:1.0];
    [[NSColor blackColor] setFill];
    [fillPath fill];
    return YES;
  }];
  image.template = YES;
  return image;
}

static NSImage *dualDisplayIcon(BOOL fillRight)
{
  NSImage *image = [NSImage imageWithSize:NSMakeSize(18.0, 14.0) flipped:NO drawingHandler:^BOOL(NSRect dstRect) {
    NSRect leftRect = NSMakeRect(1.0, 2.0, 7.0, 10.0);
    NSRect rightRect = NSMakeRect(10.0, 2.0, 7.0, 10.0);
    NSBezierPath *leftPath = [NSBezierPath bezierPathWithRoundedRect:leftRect xRadius:1.5 yRadius:1.5];
    NSBezierPath *rightPath = [NSBezierPath bezierPathWithRoundedRect:rightRect xRadius:1.5 yRadius:1.5];
    leftPath.lineWidth = 1.1;
    rightPath.lineWidth = 1.1;
    [[NSColor blackColor] setStroke];
    [leftPath stroke];
    [rightPath stroke];

    NSRect target = fillRight ? NSInsetRect(rightRect, 1.5, 1.5) : NSInsetRect(leftRect, 1.5, 1.5);
    [[NSColor blackColor] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:target xRadius:0.8 yRadius:0.8] fill];
    return YES;
  }];
  image.template = YES;
  return image;
}

static NSImage *iconForShortcutName(NSString *shortcutName)
{
  if ([shortcutName isEqualToString:@"MoveToLeftHalf"]) {
    return schematicIconWithFilledRect(^NSRect(NSRect r) {
      return NSMakeRect(r.origin.x, r.origin.y, r.size.width * 0.48, r.size.height);
    });
  }
  if ([shortcutName isEqualToString:@"MoveToRightHalf"]) {
    return schematicIconWithFilledRect(^NSRect(NSRect r) {
      CGFloat w = r.size.width * 0.48;
      return NSMakeRect(NSMaxX(r) - w, r.origin.y, w, r.size.height);
    });
  }
  if ([shortcutName isEqualToString:@"MoveToTopHalf"]) {
    return schematicIconWithFilledRect(^NSRect(NSRect r) {
      CGFloat h = r.size.height * 0.47;
      return NSMakeRect(r.origin.x, NSMaxY(r) - h, r.size.width, h);
    });
  }
  if ([shortcutName isEqualToString:@"MoveToBottomHalf"]) {
    return schematicIconWithFilledRect(^NSRect(NSRect r) {
      return NSMakeRect(r.origin.x, r.origin.y, r.size.width, r.size.height * 0.47);
    });
  }
  if ([shortcutName isEqualToString:@"MoveToUpperLeft"]) {
    return schematicIconWithFilledRect(^NSRect(NSRect r) {
      CGFloat h = r.size.height * 0.47;
      return NSMakeRect(r.origin.x, NSMaxY(r) - h, r.size.width * 0.48, h);
    });
  }
  if ([shortcutName isEqualToString:@"MoveToLowerLeft"]) {
    return schematicIconWithFilledRect(^NSRect(NSRect r) {
      return NSMakeRect(r.origin.x, r.origin.y, r.size.width * 0.48, r.size.height * 0.47);
    });
  }
  if ([shortcutName isEqualToString:@"MoveToUpperRight"]) {
    return schematicIconWithFilledRect(^NSRect(NSRect r) {
      CGFloat w = r.size.width * 0.48;
      CGFloat h = r.size.height * 0.47;
      return NSMakeRect(NSMaxX(r) - w, NSMaxY(r) - h, w, h);
    });
  }
  if ([shortcutName isEqualToString:@"MoveToLowerRight"]) {
    return schematicIconWithFilledRect(^NSRect(NSRect r) {
      CGFloat w = r.size.width * 0.48;
      return NSMakeRect(NSMaxX(r) - w, r.origin.y, w, r.size.height * 0.47);
    });
  }
  if ([shortcutName isEqualToString:@"MoveToCenter"]) {
    return schematicIconWithFilledRect(^NSRect(NSRect r) {
      return NSInsetRect(r, r.size.width * 0.2, r.size.height * 0.18);
    });
  }
  if ([shortcutName isEqualToString:@"MoveToFullscreen"]) {
    return schematicIconWithFilledRect(^NSRect(NSRect r) {
      return r;
    });
  }
  if ([shortcutName isEqualToString:@"MoveToNextThird"]) {
    return schematicIconWithFilledRect(^NSRect(NSRect r) {
      CGFloat w = r.size.width * 0.32;
      return NSMakeRect(NSMaxX(r) - w, r.origin.y, w, r.size.height);
    });
  }
  if ([shortcutName isEqualToString:@"MoveToPreviousThird"]) {
    return schematicIconWithFilledRect(^NSRect(NSRect r) {
      return NSMakeRect(r.origin.x, r.origin.y, r.size.width * 0.32, r.size.height);
    });
  }
  if ([shortcutName isEqualToString:@"MoveToNextDisplay"]) {
    return dualDisplayIcon(YES);
  }
  if ([shortcutName isEqualToString:@"MoveToPreviousDisplay"]) {
    return dualDisplayIcon(NO);
  }

  NSString *symbolName = nil;
  if ([shortcutName isEqualToString:@"MakeLarger"]) {
    symbolName = @"arrow.up.left.and.arrow.down.right";
  } else if ([shortcutName isEqualToString:@"MakeSmaller"]) {
    symbolName = @"arrow.down.right.and.arrow.up.left";
  } else if ([shortcutName isEqualToString:@"UndoLastMove"]) {
    symbolName = @"arrow.uturn.backward";
  } else if ([shortcutName isEqualToString:@"RedoLastMove"]) {
    symbolName = @"arrow.uturn.forward";
  }
  if (symbolName) {
    NSImage *symbol = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:nil];
    NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration configurationWithPointSize:12.0 weight:NSFontWeightMedium];
    return [symbol imageWithSymbolConfiguration:config];
  }
  return nil;
}

#pragma mark - Controller Implementation

@implementation SpectaclePreferencesController
{
  SpectacleShortcutManager *_shortcutManager;
  SpectacleWindowPositionManager *_windowPositionManager;
  id<SpectacleShortcutStorage> _shortcutStorage;

  NSMutableDictionary<NSString *, SpectacleShortcutRecorder *> *_shortcutRecorders;
  BOOL _shortcutsWereEnabledBeforeRecording;
  NSInteger _activeRecordingCount;

  NSToolbar *_toolbar;
  NSSegmentedControl *_tabSegmentedControl;
  NSString *_selectedTabIdentifier;

  NSStackView *_rootStack;
  NSView *_accessibilityBanner;
  NSView *_tabContentHost;

  NSView *_shortcutsTabView;
  NSView *_generalTabView;
  NSView *_disabledAppsTabView;

  NSButton *_loginItemCheckbox;
  NSButton *_statusItemCheckbox;
  NSButton *_autoUpdateCheckbox;
  NSButton *_checkForUpdatesButton;
  NSTextField *_updateStatusLabel;

  NSTableView *_disabledAppsTableView;
  NSButton *_removeAppButton;
  NSArray<SpectacleAppListEntry *> *_appListEntries;
}

- (instancetype)initWithShortcutManager:(SpectacleShortcutManager *)shortcutManager
                  windowPositionManager:(SpectacleWindowPositionManager *)windowPositionManager
                        shortcutStorage:(id<SpectacleShortcutStorage>)shortcutStorage
{
  if (self = [super initWithWindow:nil]) {
    _shortcutManager = shortcutManager;
    _windowPositionManager = windowPositionManager;
    _shortcutStorage = shortcutStorage;
    _shortcutRecorders = [NSMutableDictionary new];
    _appListEntries = @[];

    [self buildWindow];
    [self observeNotifications];
  }
  return self;
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)observeNotifications
{
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(refreshAccessibilityBanner)
                                               name:NSApplicationDidBecomeActiveNotification
                                             object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(reloadDisabledAppsList)
                                               name:SpectacleDisabledApplicationsDidChangeNotification
                                             object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(updateGeneralControls)
                                               name:SpectacleUpdateControllerDidChangeStateNotification
                                             object:nil];
}

- (void)showWindow:(id)sender
{
  [self loadRegisteredShortcuts];
  [self updateGeneralControls];
  [self reloadDisabledAppsList];
  [self refreshAccessibilityBanner];
  [self resizeWindowToFitAnimated:NO];
  [super showWindow:sender];
}

#pragma mark - Window & Toolbar Construction

- (void)buildWindow
{
  NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 680, 480)
                                                 styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskFullSizeContentView)
                                                   backing:NSBackingStoreBuffered
                                                     defer:NO];
  window.releasedWhenClosed = NO;
  window.toolbarStyle = NSWindowToolbarStyleUnified;
  window.titleVisibility = NSWindowTitleHidden;

  _toolbar = [[NSToolbar alloc] initWithIdentifier:@"SpectacleSettingsToolbar"];
  _toolbar.delegate = self;
  _toolbar.displayMode = NSToolbarDisplayModeIconOnly;
  _toolbar.allowsUserCustomization = NO;
  window.toolbar = _toolbar;

  _accessibilityBanner = [self buildAccessibilityBanner];
  _tabContentHost = [NSView new];
  _tabContentHost.translatesAutoresizingMaskIntoConstraints = NO;

  _rootStack = [NSStackView stackViewWithViews:@[_accessibilityBanner, _tabContentHost]];
  _rootStack.orientation = NSUserInterfaceLayoutOrientationVertical;
  _rootStack.alignment = NSLayoutAttributeCenterX;
  _rootStack.spacing = 0.0;
  _rootStack.translatesAutoresizingMaskIntoConstraints = NO;

  NSView *container = [NSView new];
  [container addSubview:_rootStack];
  window.contentView = container;

  NSLayoutGuide *contentLayoutGuide = window.contentLayoutGuide;
  [NSLayoutConstraint activateConstraints:@[
    [_rootStack.topAnchor constraintEqualToAnchor:contentLayoutGuide.topAnchor],
    [_rootStack.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
    [_rootStack.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
    [_rootStack.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
    [_accessibilityBanner.widthAnchor constraintEqualToAnchor:_rootStack.widthAnchor],
    [_tabContentHost.widthAnchor constraintEqualToAnchor:_rootStack.widthAnchor],
  ]];

  self.window = window;

  _shortcutsTabView = [self buildShortcutsTabView];
  _generalTabView = [self buildGeneralTabView];
  _disabledAppsTabView = [self buildDisabledAppsTabView];

  [self refreshAccessibilityBanner];
  [self selectTabWithIdentifier:SpectacleSettingsTabShortcutsIdentifier animated:NO];
  [window center];
}

- (NSView *)buildAccessibilityBanner
{
  SpectacleCardView *card = [SpectacleCardView new];
  card.cardCornerRadius = 12.0;
  card.cardBorderWidth = 0.5;
  card.cardBorderColor = [[NSColor systemOrangeColor] colorWithAlphaComponent:0.35];
  card.cardFillColor = [[NSColor systemOrangeColor] colorWithAlphaComponent:0.10];
  [card updateLayerAppearance];
  card.translatesAutoresizingMaskIntoConstraints = NO;

  NSImage *warnImage = [NSImage imageWithSystemSymbolName:@"exclamationmark.triangle.fill"
                                 accessibilityDescription:nil];
  NSImageView *iconView = [NSImageView imageViewWithImage:warnImage];
  iconView.contentTintColor = [NSColor systemOrangeColor];
  iconView.translatesAutoresizingMaskIntoConstraints = NO;
  [iconView.widthAnchor constraintEqualToConstant:16.0].active = YES;
  [iconView.heightAnchor constraintEqualToConstant:16.0].active = YES;

  NSTextField *messageLabel = [NSTextField wrappingLabelWithString:NSLocalizedString(@"AccessibilityBannerMessage", @"Banner message when Accessibility is not granted")];
  messageLabel.font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium];
  messageLabel.textColor = [NSColor labelColor];
  [messageLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
  [messageLabel setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

  NSButton *openButton = [NSButton buttonWithTitle:NSLocalizedString(@"AccessibilityBannerOpenSettingsButton", @"Open System Settings button")
                                            target:self
                                            action:@selector(openAccessibilitySettings:)];
  openButton.controlSize = NSControlSizeSmall;
  [openButton setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
  [openButton setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];

  NSStackView *row = [NSStackView stackViewWithViews:@[iconView, messageLabel, openButton]];
  row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  row.alignment = NSLayoutAttributeCenterY;
  row.spacing = 10.0;
  row.translatesAutoresizingMaskIntoConstraints = NO;

  [card addSubview:row];
  [NSLayoutConstraint activateConstraints:@[
    [row.topAnchor constraintEqualToAnchor:card.topAnchor constant:8.0],
    [row.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-8.0],
    [row.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12.0],
    [row.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12.0],
  ]];

  NSView *wrapper = [NSView new];
  wrapper.translatesAutoresizingMaskIntoConstraints = NO;
  [wrapper addSubview:card];
  [NSLayoutConstraint activateConstraints:@[
    [card.topAnchor constraintEqualToAnchor:wrapper.topAnchor constant:12.0],
    [card.bottomAnchor constraintEqualToAnchor:wrapper.bottomAnchor constant:0.0],
    [card.leadingAnchor constraintEqualToAnchor:wrapper.leadingAnchor constant:20.0],
    [card.trailingAnchor constraintEqualToAnchor:wrapper.trailingAnchor constant:-20.0],
  ]];

  return wrapper;
}

- (void)refreshAccessibilityBanner
{
  BOOL trusted = AXIsProcessTrustedWithOptions(NULL);
  BOOL shouldHide = trusted;
  if (_accessibilityBanner.hidden != shouldHide) {
    _accessibilityBanner.hidden = shouldHide;
    if (self.window.isVisible) {
      [self resizeWindowToFitAnimated:YES];
    }
  }
}

#pragma mark - NSToolbarDelegate

- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar
{
  return @[
    NSToolbarFlexibleSpaceItemIdentifier,
    SpectacleToolbarTabSwitcherIdentifier,
  ];
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar
{
  return @[
    NSToolbarFlexibleSpaceItemIdentifier,
    SpectacleToolbarTabSwitcherIdentifier,
    NSToolbarFlexibleSpaceItemIdentifier,
  ];
}

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar
     itemForItemIdentifier:(NSToolbarItemIdentifier)itemIdentifier
 willBeInsertedIntoToolbar:(BOOL)flag
{
  if (![itemIdentifier isEqualToString:SpectacleToolbarTabSwitcherIdentifier]) {
    return nil;
  }

  NSArray<NSString *> *labels = @[
    NSLocalizedString(@"SettingsTabShortcuts", @"Shortcuts tab title"),
    NSLocalizedString(@"SettingsTabGeneral", @"General tab title"),
    NSLocalizedString(@"SettingsTabDisabledApps", @"Disabled Apps tab title"),
  ];
  NSArray<NSString *> *symbols = @[@"keyboard", @"gearshape", @"nosign"];

  _tabSegmentedControl = [NSSegmentedControl segmentedControlWithLabels:labels
                                                           trackingMode:NSSegmentSwitchTrackingSelectOne
                                                                 target:self
                                                                 action:@selector(tabSegmentChanged:)];
  _tabSegmentedControl.segmentStyle = NSSegmentStyleAutomatic;
  _tabSegmentedControl.segmentDistribution = NSSegmentDistributionFit;
  _tabSegmentedControl.controlSize = NSControlSizeRegular;

  NSImageSymbolConfiguration *symbolConfig = [NSImageSymbolConfiguration configurationWithPointSize:12.5 weight:NSFontWeightMedium];
  for (NSInteger i = 0; i < (NSInteger)symbols.count; i++) {
    NSImage *image = [[NSImage imageWithSystemSymbolName:symbols[i] accessibilityDescription:labels[i]]
                      imageWithSymbolConfiguration:symbolConfig];
    [_tabSegmentedControl setImage:image forSegment:i];
    [_tabSegmentedControl setImageScaling:NSImageScaleProportionallyDown forSegment:i];
  }
  _tabSegmentedControl.selectedSegment = 0;

  NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier];
  item.view = _tabSegmentedControl;
  item.bordered = NO;
  return item;
}

- (void)tabSegmentChanged:(NSSegmentedControl *)sender
{
  NSArray<NSString *> *identifiers = @[
    SpectacleSettingsTabShortcutsIdentifier,
    SpectacleSettingsTabGeneralIdentifier,
    SpectacleSettingsTabDisabledAppsIdentifier,
  ];
  NSInteger index = sender.selectedSegment;
  if (index >= 0 && index < (NSInteger)identifiers.count) {
    [self selectTabWithIdentifier:identifiers[index] animated:YES];
  }
}

- (void)selectTabWithIdentifier:(NSString *)identifier animated:(BOOL)animated
{
  if ([_selectedTabIdentifier isEqualToString:identifier]) {
    return;
  }

  _selectedTabIdentifier = [identifier copy];

  NSView *targetView = nil;
  NSString *title = nil;
  NSInteger segmentIndex = 0;
  if ([identifier isEqualToString:SpectacleSettingsTabShortcutsIdentifier]) {
    targetView = _shortcutsTabView;
    title = NSLocalizedString(@"SettingsTabShortcuts", @"Shortcuts tab title");
    segmentIndex = 0;
    [self loadRegisteredShortcuts];
  } else if ([identifier isEqualToString:SpectacleSettingsTabGeneralIdentifier]) {
    targetView = _generalTabView;
    title = NSLocalizedString(@"SettingsTabGeneral", @"General tab title");
    segmentIndex = 1;
    [self updateGeneralControls];
  } else if ([identifier isEqualToString:SpectacleSettingsTabDisabledAppsIdentifier]) {
    targetView = _disabledAppsTabView;
    title = NSLocalizedString(@"SettingsTabDisabledApps", @"Disabled Apps tab title");
    segmentIndex = 2;
    [self reloadDisabledAppsList];
  }

  if (!targetView) {
    return;
  }

  _tabSegmentedControl.selectedSegment = segmentIndex;

  // Stop any active recording when switching tabs
  [self.window makeFirstResponder:nil];

  for (NSView *subview in [_tabContentHost.subviews copy]) {
    [subview removeFromSuperview];
  }

  targetView.translatesAutoresizingMaskIntoConstraints = NO;
  [_tabContentHost addSubview:targetView];
  [NSLayoutConstraint activateConstraints:@[
    [targetView.topAnchor constraintEqualToAnchor:_tabContentHost.topAnchor],
    [targetView.bottomAnchor constraintEqualToAnchor:_tabContentHost.bottomAnchor],
    [targetView.leadingAnchor constraintEqualToAnchor:_tabContentHost.leadingAnchor],
    [targetView.trailingAnchor constraintEqualToAnchor:_tabContentHost.trailingAnchor],
  ]];

  self.window.title = title;
  [self resizeWindowToFitAnimated:animated];
}

- (void)resizeWindowToFitAnimated:(BOOL)animated
{
  NSView *contentView = self.window.contentView;
  [contentView layoutSubtreeIfNeeded];
  NSSize stackSize = _rootStack.fittingSize;
  CGFloat titlebarHeight = self.window.frame.size.height - self.window.contentLayoutRect.size.height;
  NSSize targetFrameSize = NSMakeSize(stackSize.width, stackSize.height + titlebarHeight);

  NSRect currentFrame = self.window.frame;
  NSRect targetFrame = NSMakeRect(currentFrame.origin.x,
                                  NSMaxY(currentFrame) - targetFrameSize.height,
                                  targetFrameSize.width,
                                  targetFrameSize.height);

  [self.window setFrame:targetFrame display:YES animate:animated];
}

#pragma mark - Card Helper

- (NSView *)buildCardWithTitle:(NSString *)title bodyView:(NSView *)bodyView
{
  SpectacleCardView *card = [SpectacleCardView new];
  card.translatesAutoresizingMaskIntoConstraints = NO;
  [card setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationVertical];

  NSTextField *headerLabel = [NSTextField labelWithString:title];
  headerLabel.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightSemibold];
  headerLabel.textColor = [NSColor secondaryLabelColor];

  bodyView.translatesAutoresizingMaskIntoConstraints = NO;

  NSStackView *stack = [NSStackView stackViewWithViews:@[headerLabel, bodyView]];
  stack.orientation = NSUserInterfaceLayoutOrientationVertical;
  stack.alignment = NSLayoutAttributeLeading;
  stack.spacing = 10.0;
  stack.translatesAutoresizingMaskIntoConstraints = NO;

  [card addSubview:stack];
  [NSLayoutConstraint activateConstraints:@[
    [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:11.0],
    [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-12.0],
    [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14.0],
    [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14.0],
    [bodyView.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
  ]];

  return card;
}

#pragma mark - Tab 1: Shortcuts

- (NSView *)buildShortcutsTabView
{
  NSView *halvesCard = [self buildShortcutCardWithTitle:NSLocalizedString(@"ShortcutCategoryHalves", @"Halves section title")
                                          shortcutNames:@[@"MoveToLeftHalf", @"MoveToRightHalf", @"MoveToTopHalf", @"MoveToBottomHalf"]];
  NSView *quartersCard = [self buildShortcutCardWithTitle:NSLocalizedString(@"ShortcutCategoryQuarters", @"Quarters section title")
                                            shortcutNames:@[@"MoveToUpperLeft", @"MoveToLowerLeft", @"MoveToUpperRight", @"MoveToLowerRight"]];
  NSView *historyCard = [self buildShortcutCardWithTitle:NSLocalizedString(@"ShortcutCategoryHistory", @"History section title")
                                           shortcutNames:@[@"UndoLastMove", @"RedoLastMove"]];

  NSView *positionSizeCard = [self buildShortcutCardWithTitle:NSLocalizedString(@"ShortcutCategoryPositionAndSize", @"Position & Size section title")
                                                shortcutNames:@[@"MoveToCenter", @"MoveToFullscreen", @"MakeLarger", @"MakeSmaller"]];
  NSView *thirdsCard = [self buildShortcutCardWithTitle:NSLocalizedString(@"ShortcutCategoryThirds", @"Thirds section title")
                                          shortcutNames:@[@"MoveToNextThird", @"MoveToPreviousThird"]];
  NSView *displaysCard = [self buildShortcutCardWithTitle:NSLocalizedString(@"ShortcutCategoryDisplays", @"Displays section title")
                                            shortcutNames:@[@"MoveToNextDisplay", @"MoveToPreviousDisplay"]];

  NSStackView *leftColumn = [NSStackView stackViewWithViews:@[halvesCard, quartersCard, historyCard]];
  leftColumn.orientation = NSUserInterfaceLayoutOrientationVertical;
  leftColumn.alignment = NSLayoutAttributeLeading;
  leftColumn.spacing = 12.0;
  [leftColumn setHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationVertical];

  NSStackView *rightColumn = [NSStackView stackViewWithViews:@[positionSizeCard, thirdsCard, displaysCard]];
  rightColumn.orientation = NSUserInterfaceLayoutOrientationVertical;
  rightColumn.alignment = NSLayoutAttributeLeading;
  rightColumn.spacing = 12.0;
  [rightColumn setHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationVertical];

  NSStackView *columns = [NSStackView stackViewWithViews:@[leftColumn, rightColumn]];
  columns.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  columns.alignment = NSLayoutAttributeTop;
  columns.spacing = 14.0;

  [NSLayoutConstraint activateConstraints:@[
    [halvesCard.widthAnchor constraintEqualToAnchor:leftColumn.widthAnchor],
    [quartersCard.widthAnchor constraintEqualToAnchor:leftColumn.widthAnchor],
    [historyCard.widthAnchor constraintEqualToAnchor:leftColumn.widthAnchor],

    [positionSizeCard.widthAnchor constraintEqualToAnchor:rightColumn.widthAnchor],
    [thirdsCard.widthAnchor constraintEqualToAnchor:rightColumn.widthAnchor],
    [displaysCard.widthAnchor constraintEqualToAnchor:rightColumn.widthAnchor],
    [leftColumn.widthAnchor constraintEqualToAnchor:rightColumn.widthAnchor],
  ]];

  NSButton *importButton = [NSButton buttonWithTitle:NSLocalizedString(@"ButtonLabelImportShortcuts", @"Import shortcuts button")
                                              target:self
                                              action:@selector(importShortcuts:)];
  NSButton *exportButton = [NSButton buttonWithTitle:NSLocalizedString(@"ButtonLabelExportShortcuts", @"Export shortcuts button")
                                              target:self
                                              action:@selector(exportShortcuts:)];
  NSButton *restoreButton = [NSButton buttonWithTitle:NSLocalizedString(@"ButtonLabelRestoreDefaults", @"Restore defaults button")
                                               target:self
                                               action:@selector(restoreDefaults:)];

  NSView *spacer = [NSView new];
  [spacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

  NSStackView *footerBar = [NSStackView stackViewWithViews:@[importButton, exportButton, spacer, restoreButton]];
  footerBar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  footerBar.alignment = NSLayoutAttributeCenterY;
  footerBar.spacing = 8.0;

  NSStackView *content = [NSStackView stackViewWithViews:@[columns, footerBar]];
  content.orientation = NSUserInterfaceLayoutOrientationVertical;
  content.alignment = NSLayoutAttributeLeading;
  content.spacing = 16.0;
  content.translatesAutoresizingMaskIntoConstraints = NO;

  NSView *container = [NSView new];
  [container addSubview:content];
  [NSLayoutConstraint activateConstraints:@[
    [content.topAnchor constraintEqualToAnchor:container.topAnchor constant:16.0],
    [content.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-16.0],
    [content.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:20.0],
    [content.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-20.0],
    [footerBar.widthAnchor constraintEqualToAnchor:content.widthAnchor],
  ]];

  return container;
}

- (NSView *)buildShortcutCardWithTitle:(NSString *)title shortcutNames:(NSArray<NSString *> *)shortcutNames
{
  NSMutableArray<NSArray<NSView *> *> *rows = [NSMutableArray new];

  for (NSString *shortcutName in shortcutNames) {
    NSImage *icon = iconForShortcutName(shortcutName);
    NSImageView *iconView = [NSImageView imageViewWithImage:icon];
    iconView.contentTintColor = [NSColor secondaryLabelColor];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    [iconView.widthAnchor constraintEqualToConstant:18.0].active = YES;
    [iconView.heightAnchor constraintEqualToConstant:16.0].active = YES;

    NSString *actionTitle = localizedLabelForShortcutName(shortcutName);
    NSTextField *label = [NSTextField labelWithString:actionTitle];
    label.font = [NSFont systemFontOfSize:13.0];
    label.textColor = [NSColor labelColor];
    label.alignment = NSTextAlignmentLeft;
    [label setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [label setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];

    SpectacleShortcutRecorder *recorder = [SpectacleShortcutRecorder new];
    recorder.translatesAutoresizingMaskIntoConstraints = NO;
    [recorder.widthAnchor constraintEqualToConstant:148.0].active = YES;
    [recorder.heightAnchor constraintEqualToConstant:24.0].active = YES;
    recorder.shortcutName = shortcutName;
    recorder.actionTitle = actionTitle;
    recorder.delegate = self;

    _shortcutRecorders[shortcutName] = recorder;
    [rows addObject:@[iconView, label, recorder]];
  }

  NSGridView *grid = [NSGridView gridViewWithViews:rows];
  grid.rowSpacing = 8.0;
  grid.columnSpacing = 10.0;
  grid.yPlacement = NSGridCellPlacementCenter;
  [grid setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationVertical];
  [grid columnAtIndex:0].xPlacement = NSGridCellPlacementCenter;
  [grid columnAtIndex:0].width = 18.0;
  [grid columnAtIndex:1].xPlacement = NSGridCellPlacementLeading;
  [grid columnAtIndex:2].xPlacement = NSGridCellPlacementTrailing;
  [grid columnAtIndex:2].width = 148.0;
  [grid columnAtIndex:1].leadingPadding = -2.0;

  return [self buildCardWithTitle:title bodyView:grid];
}

#pragma mark - Tab 2: General

- (NSView *)buildGeneralTabView
{
  _loginItemCheckbox = [NSButton checkboxWithTitle:NSLocalizedString(@"GeneralLaunchAtLogin", @"Launch at login checkbox")
                                            target:self
                                            action:@selector(toggleLoginItem:)];

  _statusItemCheckbox = [NSButton checkboxWithTitle:NSLocalizedString(@"GeneralShowInMenuBar", @"Show icon in menu bar checkbox")
                                             target:self
                                             action:@selector(toggleStatusItem:)];

  NSStackView *startupStack = [NSStackView stackViewWithViews:@[_loginItemCheckbox, _statusItemCheckbox]];
  startupStack.orientation = NSUserInterfaceLayoutOrientationVertical;
  startupStack.alignment = NSLayoutAttributeLeading;
  startupStack.spacing = 10.0;

  NSView *startupCard = [self buildCardWithTitle:NSLocalizedString(@"GeneralSectionStartupAndMenuBar", @"Startup & Menu Bar section")
                                        bodyView:startupStack];

  // Updates card
  _autoUpdateCheckbox = [NSButton checkboxWithTitle:NSLocalizedString(@"GeneralAutoCheckUpdates", @"Automatically check for updates checkbox")
                                             target:self
                                             action:@selector(toggleAutomaticUpdates:)];

  _checkForUpdatesButton = [NSButton buttonWithTitle:NSLocalizedString(@"ButtonLabelCheckForUpdates", @"Check for Updates button")
                                              target:self
                                              action:@selector(checkForUpdates:)];
  [_checkForUpdatesButton setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];

  _updateStatusLabel = [NSTextField labelWithString:@""];
  _updateStatusLabel.font = [NSFont systemFontOfSize:11.5];
  _updateStatusLabel.textColor = [NSColor secondaryLabelColor];
  _updateStatusLabel.lineBreakMode = NSLineBreakByTruncatingTail;

  NSStackView *updateActionRow = [NSStackView stackViewWithViews:@[_checkForUpdatesButton, _updateStatusLabel]];
  updateActionRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  updateActionRow.alignment = NSLayoutAttributeCenterY;
  updateActionRow.spacing = 10.0;

  NSStackView *updatesStack = [NSStackView stackViewWithViews:@[_autoUpdateCheckbox, updateActionRow]];
  updatesStack.orientation = NSUserInterfaceLayoutOrientationVertical;
  updatesStack.alignment = NSLayoutAttributeLeading;
  updatesStack.spacing = 10.0;

  NSView *updatesCard = [self buildCardWithTitle:NSLocalizedString(@"GeneralSectionUpdates", @"Updates section")
                                        bodyView:updatesStack];

  // About card
  NSImageView *appIconView = [NSImageView imageViewWithImage:[NSImage imageNamed:NSImageNameApplicationIcon]];
  appIconView.translatesAutoresizingMaskIntoConstraints = NO;
  [appIconView.widthAnchor constraintEqualToConstant:44.0].active = YES;
  [appIconView.heightAnchor constraintEqualToConstant:44.0].active = YES;

  NSTextField *appNameLabel = [NSTextField labelWithString:@"Spectacle"];
  appNameLabel.font = [NSFont systemFontOfSize:14.0 weight:NSFontWeightSemibold];

  NSString *versionText = [NSString stringWithFormat:NSLocalizedString(@"GeneralVersionFormat", @"Version format string"),
                           SpectacleUtilities.applicationVersion];
  NSTextField *versionLabel = [NSTextField labelWithString:versionText];
  versionLabel.font = [NSFont systemFontOfSize:11.5];
  versionLabel.textColor = [NSColor secondaryLabelColor];

  NSTextField *descriptionLabel = [NSTextField wrappingLabelWithString:NSLocalizedString(@"GeneralAppDescription", @"App description")];
  descriptionLabel.font = [NSFont systemFontOfSize:11.5];
  descriptionLabel.textColor = [NSColor secondaryLabelColor];
  [descriptionLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

  NSStackView *infoStack = [NSStackView stackViewWithViews:@[appNameLabel, versionLabel, descriptionLabel]];
  infoStack.orientation = NSUserInterfaceLayoutOrientationVertical;
  infoStack.alignment = NSLayoutAttributeLeading;
  infoStack.spacing = 2.0;

  NSButton *aboutButton = [NSButton buttonWithTitle:NSLocalizedString(@"ButtonLabelAboutSpectacle", @"About Spectacle button")
                                             target:self
                                             action:@selector(showAboutPanel:)];
  [aboutButton setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
  [aboutButton setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];

  NSStackView *aboutRow = [NSStackView stackViewWithViews:@[appIconView, infoStack, aboutButton]];
  aboutRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  aboutRow.alignment = NSLayoutAttributeCenterY;
  aboutRow.spacing = 12.0;

  NSView *aboutCard = [self buildCardWithTitle:NSLocalizedString(@"GeneralSectionAbout", @"About section")
                                      bodyView:aboutRow];

  NSStackView *content = [NSStackView stackViewWithViews:@[startupCard, updatesCard, aboutCard]];
  content.orientation = NSUserInterfaceLayoutOrientationVertical;
  content.alignment = NSLayoutAttributeLeading;
  content.spacing = 14.0;
  content.translatesAutoresizingMaskIntoConstraints = NO;

  NSView *container = [NSView new];
  [container addSubview:content];
  [NSLayoutConstraint activateConstraints:@[
    [content.widthAnchor constraintEqualToConstant:460.0],
    [content.topAnchor constraintEqualToAnchor:container.topAnchor constant:16.0],
    [content.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-18.0],
    [content.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:20.0],
    [content.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-20.0],
    [startupCard.widthAnchor constraintEqualToAnchor:content.widthAnchor],
    [updatesCard.widthAnchor constraintEqualToAnchor:content.widthAnchor],
    [aboutCard.widthAnchor constraintEqualToAnchor:content.widthAnchor],
  ]];

  return container;
}

- (void)updateGeneralControls
{
  _loginItemCheckbox.state = [SpectacleLoginItemHelper isLoginItemEnabledForBundle:NSBundle.mainBundle]
    ? NSControlStateValueOn
    : NSControlStateValueOff;
  _statusItemCheckbox.state = [NSUserDefaults.standardUserDefaults boolForKey:@"StatusItemEnabled"]
    ? NSControlStateValueOn
    : NSControlStateValueOff;

  SpectacleUpdateController *updater = [SpectacleUpdateController sharedController];
  _autoUpdateCheckbox.state = updater.automaticallyChecksForUpdates ? NSControlStateValueOn : NSControlStateValueOff;
  _checkForUpdatesButton.enabled = !updater.isBusy;

  if (updater.statusMessage.length > 0) {
    _updateStatusLabel.stringValue = updater.statusMessage;
  } else if (updater.lastUpdateCheckDate) {
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.dateStyle = NSDateFormatterShortStyle;
    formatter.timeStyle = NSDateFormatterShortStyle;
    formatter.doesRelativeDateFormatting = YES;
    _updateStatusLabel.stringValue = [NSString stringWithFormat:NSLocalizedString(@"UpdateLastCheckedFormat", @"Last checked format"),
                                      [formatter stringFromDate:updater.lastUpdateCheckDate]];
  } else {
    _updateStatusLabel.stringValue = NSLocalizedString(@"UpdateLastCheckedNever", @"Never checked status");
  }
}

#pragma mark - Tab 3: Disabled Apps

- (NSView *)buildDisabledAppsTabView
{
  NSTextField *descriptionLabel = [NSTextField wrappingLabelWithString:NSLocalizedString(@"DisabledAppsDescription", @"Disabled apps explanation")];
  descriptionLabel.font = [NSFont systemFontOfSize:12.0];
  descriptionLabel.textColor = [NSColor secondaryLabelColor];
  descriptionLabel.preferredMaxLayoutWidth = 460.0;

  _disabledAppsTableView = [NSTableView new];
  _disabledAppsTableView.headerView = nil;
  _disabledAppsTableView.rowHeight = 44.0;
  _disabledAppsTableView.intercellSpacing = NSMakeSize(0, 2.0);
  _disabledAppsTableView.style = NSTableViewStyleInset;
  _disabledAppsTableView.backgroundColor = [NSColor clearColor];
  _disabledAppsTableView.dataSource = self;
  _disabledAppsTableView.delegate = self;

  NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"AppColumn"];
  column.resizingMask = NSTableColumnAutoresizingMask;
  [_disabledAppsTableView addTableColumn:column];

  NSScrollView *scrollView = [NSScrollView new];
  scrollView.documentView = _disabledAppsTableView;
  scrollView.hasVerticalScroller = YES;
  scrollView.autohidesScrollers = YES;
  scrollView.borderType = NSNoBorder;
  scrollView.drawsBackground = NO;
  scrollView.translatesAutoresizingMaskIntoConstraints = NO;
  [scrollView.heightAnchor constraintEqualToConstant:230.0].active = YES;

  SpectacleCardView *tableCard = [SpectacleCardView new];
  tableCard.translatesAutoresizingMaskIntoConstraints = NO;
  tableCard.layer.masksToBounds = YES;
  [tableCard addSubview:scrollView];
  [NSLayoutConstraint activateConstraints:@[
    [scrollView.topAnchor constraintEqualToAnchor:tableCard.topAnchor constant:4.0],
    [scrollView.bottomAnchor constraintEqualToAnchor:tableCard.bottomAnchor constant:-4.0],
    [scrollView.leadingAnchor constraintEqualToAnchor:tableCard.leadingAnchor],
    [scrollView.trailingAnchor constraintEqualToAnchor:tableCard.trailingAnchor],
  ]];

  NSButton *addButton = [NSButton buttonWithTitle:NSLocalizedString(@"DisabledAppsAddButton", @"Add application button")
                                           target:self
                                           action:@selector(addDisabledApplication:)];
  _removeAppButton = [NSButton buttonWithTitle:NSLocalizedString(@"DisabledAppsRemoveButton", @"Remove application button")
                                        target:self
                                        action:@selector(removeSelectedDisabledApplication:)];
  _removeAppButton.enabled = NO;

  NSView *spacer = [NSView new];
  [spacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

  NSStackView *buttonBar = [NSStackView stackViewWithViews:@[addButton, _removeAppButton, spacer]];
  buttonBar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  buttonBar.alignment = NSLayoutAttributeCenterY;
  buttonBar.spacing = 8.0;

  NSStackView *content = [NSStackView stackViewWithViews:@[descriptionLabel, tableCard, buttonBar]];
  content.orientation = NSUserInterfaceLayoutOrientationVertical;
  content.alignment = NSLayoutAttributeLeading;
  content.spacing = 12.0;
  content.translatesAutoresizingMaskIntoConstraints = NO;

  NSView *container = [NSView new];
  [container addSubview:content];
  [NSLayoutConstraint activateConstraints:@[
    [content.widthAnchor constraintEqualToConstant:460.0],
    [content.topAnchor constraintEqualToAnchor:container.topAnchor constant:16.0],
    [content.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-16.0],
    [content.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:20.0],
    [content.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-20.0],
    [tableCard.widthAnchor constraintEqualToAnchor:content.widthAnchor],
    [buttonBar.widthAnchor constraintEqualToAnchor:content.widthAnchor],
  ]];

  return container;
}

- (SpectacleAppListEntry *)entryForBundleIdentifier:(NSString *)bundleIdentifier isBuiltIn:(BOOL)isBuiltIn
{
  SpectacleAppListEntry *entry = [SpectacleAppListEntry new];
  entry.bundleIdentifier = bundleIdentifier;
  entry.isBuiltIn = isBuiltIn;

  NSWorkspace *workspace = [NSWorkspace sharedWorkspace];
  NSURL *appURL = [workspace URLForApplicationWithBundleIdentifier:bundleIdentifier];
  if (appURL) {
    NSBundle *bundle = [NSBundle bundleWithURL:appURL];
    NSString *name = [bundle objectForInfoDictionaryKey:@"CFBundleDisplayName"]
      ?: [bundle objectForInfoDictionaryKey:@"CFBundleName"]
      ?: appURL.URLByDeletingPathExtension.lastPathComponent;
    entry.displayName = name ?: bundleIdentifier;
    entry.icon = [workspace iconForFile:appURL.path];
  } else {
    entry.displayName = bundleIdentifier.pathExtension.length > 0 ? bundleIdentifier.pathExtension.capitalizedString : bundleIdentifier;
    entry.icon = [NSImage imageWithSystemSymbolName:@"app" accessibilityDescription:nil];
  }
  return entry;
}

- (void)reloadDisabledAppsList
{
  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  NSArray<NSString *> *userDisabled = [defaults arrayForKey:@"DisabledApplications"] ?: @[];
  NSArray<NSString *> *blacklisted = [defaults arrayForKey:@"BlacklistedApplications"] ?: @[];

  NSMutableArray<SpectacleAppListEntry *> *entries = [NSMutableArray new];
  NSArray<NSString *> *sortedUser = [userDisabled sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
  for (NSString *bundleID in sortedUser) {
    [entries addObject:[self entryForBundleIdentifier:bundleID isBuiltIn:NO]];
  }
  NSArray<NSString *> *sortedBuiltIn = [blacklisted sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
  for (NSString *bundleID in sortedBuiltIn) {
    if (![userDisabled containsObject:bundleID]) {
      [entries addObject:[self entryForBundleIdentifier:bundleID isBuiltIn:YES]];
    }
  }

  _appListEntries = [entries copy];
  [_disabledAppsTableView reloadData];
  [self updateRemoveButtonState];
}

- (void)updateRemoveButtonState
{
  NSInteger row = _disabledAppsTableView.selectedRow;
  BOOL canRemove = (row >= 0 && row < (NSInteger)_appListEntries.count && !_appListEntries[row].isBuiltIn);
  _removeAppButton.enabled = canRemove;
}

#pragma mark - NSTableViewDataSource & NSTableViewDelegate

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
  return _appListEntries.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
  SpectacleAppListEntry *entry = _appListEntries[row];

  NSTableCellView *cell = [NSTableCellView new];

  NSImageView *iconView = [NSImageView imageViewWithImage:entry.icon];
  iconView.translatesAutoresizingMaskIntoConstraints = NO;
  [iconView.widthAnchor constraintEqualToConstant:26.0].active = YES;
  [iconView.heightAnchor constraintEqualToConstant:26.0].active = YES;

  NSTextField *nameLabel = [NSTextField labelWithString:entry.displayName];
  nameLabel.font = [NSFont systemFontOfSize:13.0 weight:NSFontWeightMedium];
  nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;

  NSTextField *bundleLabel = [NSTextField labelWithString:entry.bundleIdentifier];
  bundleLabel.font = [NSFont systemFontOfSize:10.5];
  bundleLabel.textColor = [NSColor secondaryLabelColor];
  bundleLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;

  NSStackView *textStack = [NSStackView stackViewWithViews:@[nameLabel, bundleLabel]];
  textStack.orientation = NSUserInterfaceLayoutOrientationVertical;
  textStack.alignment = NSLayoutAttributeLeading;
  textStack.spacing = 1.0;

  NSView *spacer = [NSView new];
  [spacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

  NSView *trailingView = nil;
  if (entry.isBuiltIn) {
    NSTextField *badge = [NSTextField labelWithString:NSLocalizedString(@"DisabledAppsBuiltInBadge", @"Built-in badge label")];
    badge.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium];
    badge.textColor = [NSColor secondaryLabelColor];
    trailingView = badge;
  } else {
    NSImage *removeImage = [NSImage imageWithSystemSymbolName:@"minus.circle"
                                     accessibilityDescription:NSLocalizedString(@"DisabledAppsRemoveButton", @"Remove")];
    NSButton *removeButton = [NSButton buttonWithImage:removeImage
                                                target:self
                                                action:@selector(removeInlineDisabledApplication:)];
    removeButton.bordered = NO;
    removeButton.contentTintColor = [NSColor secondaryLabelColor];
    removeButton.tag = row;
    removeButton.toolTip = NSLocalizedString(@"DisabledAppsRemoveButton", @"Remove");
    trailingView = removeButton;
  }

  NSStackView *rowStack = [NSStackView stackViewWithViews:@[iconView, textStack, spacer, trailingView]];
  rowStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  rowStack.alignment = NSLayoutAttributeCenterY;
  rowStack.spacing = 10.0;
  rowStack.translatesAutoresizingMaskIntoConstraints = NO;

  [cell addSubview:rowStack];
  [NSLayoutConstraint activateConstraints:@[
    [rowStack.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:6.0],
    [rowStack.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-8.0],
    [rowStack.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
  ]];

  return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
  [self updateRemoveButtonState];
}

#pragma mark - Shortcut Loading & Action Helper

- (SpectacleShortcutAction)windowMoveAction
{
  __weak typeof(self) weakSelf = self;
  return ^(SpectacleShortcut *shortcut) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf) {
      return;
    }
    [strongSelf->_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                                            action:shortcut.windowAction];
  };
}

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

- (void)shortcutRecorderDidStartRecording:(SpectacleShortcutRecorder *)shortcutRecorder
{
  if (_activeRecordingCount == 0) {
    _shortcutsWereEnabledBeforeRecording = _shortcutManager.areShortcutsEnabled;
    if (_shortcutsWereEnabledBeforeRecording) {
      [_shortcutManager unregisterShortcuts];
    }
  }
  _activeRecordingCount++;
}

- (void)shortcutRecorderDidStopRecording:(SpectacleShortcutRecorder *)shortcutRecorder
{
  _activeRecordingCount = MAX(0, _activeRecordingCount - 1);
  if (_activeRecordingCount == 0 && _shortcutsWereEnabledBeforeRecording) {
    [_shortcutManager registerShortcuts];
  }
}

- (void)shortcutRecorder:(SpectacleShortcutRecorder *)shortcutRecorder
   didReceiveNewShortcut:(SpectacleShortcut *)shortcut
{
  [_shortcutManager updateShortcut:[shortcut copyWithShortcutAction:[self windowMoveAction]]];
  [self loadRegisteredShortcuts];
}

- (void)shortcutRecorder:(SpectacleShortcutRecorder *)shortcutRecorder
didClearExistingShortcut:(SpectacleShortcut *)shortcut
{
  [_shortcutManager clearShortcut:shortcut];
  [self loadRegisteredShortcuts];
}

- (void)shortcutRecorderDidRequestResetToDefault:(SpectacleShortcutRecorder *)shortcutRecorder
{
  SpectacleShortcut *defaultShortcut = SpectacleDefaultShortcutForNameWithAction(shortcutRecorder.shortcutName,
                                                                                 [self windowMoveAction]);
  if (!defaultShortcut) {
    return;
  }
  [_shortcutManager updateShortcut:defaultShortcut];
  [self loadRegisteredShortcuts];
}

#pragma mark - Actions: Shortcuts Tab

- (IBAction)importShortcuts:(id)sender
{
  NSOpenPanel *panel = [NSOpenPanel openPanel];
  panel.allowedContentTypes = @[UTTypeJSON];
  panel.canChooseDirectories = NO;
  panel.allowsMultipleSelection = NO;

  [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
    if (result != NSModalResponseOK || !panel.URL) {
      return;
    }
    NSError *error = nil;
    NSData *data = [NSData dataWithContentsOfURL:panel.URL options:0 error:&error];
    NSArray<SpectacleShortcut *> *shortcuts = nil;
    if (data) {
      shortcuts = [SpectacleShortcutJSONStorage shortcutsFromJSONData:data
                                                               action:[self windowMoveAction]
                                                                error:&error];
    }
    if (!shortcuts || shortcuts.count == 0) {
      NSAlert *alert = [NSAlert new];
      alert.alertStyle = NSAlertStyleWarning;
      alert.messageText = NSLocalizedString(@"AlertMessageTextImportFailed", @"Import failed title");
      alert.informativeText = error.localizedDescription ?: NSLocalizedString(@"AlertInformativeTextImportInvalidFile", @"Invalid file message");
      [alert beginSheetModalForWindow:self.window completionHandler:nil];
      return;
    }
    [self->_shortcutManager updateShortcuts:shortcuts];
    [self loadRegisteredShortcuts];
  }];
}

- (IBAction)exportShortcuts:(id)sender
{
  NSSavePanel *panel = [NSSavePanel savePanel];
  panel.allowedContentTypes = @[UTTypeJSON];
  panel.nameFieldStringValue = @"Spectacle-Shortcuts.json";

  [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
    if (result != NSModalResponseOK || !panel.URL) {
      return;
    }
    NSError *error = nil;
    NSData *data = [SpectacleShortcutJSONStorage JSONDataFromShortcuts:[self->_shortcutManager shortcuts] error:&error];
    if (!data || ![data writeToURL:panel.URL options:NSDataWritingAtomic error:&error]) {
      NSAlert *alert = [NSAlert new];
      alert.alertStyle = NSAlertStyleWarning;
      alert.messageText = NSLocalizedString(@"AlertMessageTextExportFailed", @"Export failed title");
      alert.informativeText = error.localizedDescription ?: @"";
      [alert beginSheetModalForWindow:self.window completionHandler:nil];
    }
  }];
}

- (IBAction)restoreDefaults:(id)sender
{
  [SpectacleUtilities displayRestoreDefaultsAlertWithConfirmationCallback:^{
    NSArray<SpectacleShortcut *> *shortcuts = SpectacleDefaultShortcutsWithAction([self windowMoveAction]);
    [self->_shortcutManager updateShortcuts:shortcuts];
    [self loadRegisteredShortcuts];
  }];
}

#pragma mark - Actions: General Tab

- (IBAction)toggleLoginItem:(id)sender
{
  NSBundle *applicationBundle = NSBundle.mainBundle;
  if (_loginItemCheckbox.state == NSControlStateValueOn) {
    [SpectacleLoginItemHelper enableLoginItemForBundle:applicationBundle];
  } else {
    [SpectacleLoginItemHelper disableLoginItemForBundle:applicationBundle];
  }
  _loginItemCheckbox.state = [SpectacleLoginItemHelper isLoginItemEnabledForBundle:applicationBundle]
    ? NSControlStateValueOn
    : NSControlStateValueOff;
}

- (IBAction)toggleStatusItem:(id)sender
{
  BOOL enabled = (_statusItemCheckbox.state == NSControlStateValueOn);
  NSUserDefaults *userDefaults = NSUserDefaults.standardUserDefaults;
  if (!enabled && ![userDefaults boolForKey:@"BackgroundAlertSuppressed"]) {
    [SpectacleUtilities displayRunningInBackgroundAlertWithCallback:^(BOOL isConfirmed, BOOL isSuppressed) {
      if (!isConfirmed) {
        self->_statusItemCheckbox.state = NSControlStateValueOn;
        return;
      }
      [userDefaults setBool:isSuppressed forKey:@"BackgroundAlertSuppressed"];
      [userDefaults setBool:NO forKey:@"StatusItemEnabled"];
      [[NSNotificationCenter defaultCenter] postNotificationName:@"SpectacleStatusItemDisabledNotification" object:self];
    }];
    return;
  }
  NSString *notificationName = enabled ? @"SpectacleStatusItemEnabledNotification" : @"SpectacleStatusItemDisabledNotification";
  [userDefaults setBool:enabled forKey:@"StatusItemEnabled"];
  [[NSNotificationCenter defaultCenter] postNotificationName:notificationName object:self];
}

- (IBAction)toggleAutomaticUpdates:(id)sender
{
  [SpectacleUpdateController sharedController].automaticallyChecksForUpdates = (_autoUpdateCheckbox.state == NSControlStateValueOn);
}

- (IBAction)checkForUpdates:(id)sender
{
  [[SpectacleUpdateController sharedController] checkForUpdatesInitiatedByUser:YES];
}

- (IBAction)showAboutPanel:(id)sender
{
  [NSApp orderFrontStandardAboutPanel:sender];
}

#pragma mark - Actions: Disabled Apps Tab

- (IBAction)addDisabledApplication:(id)sender
{
  NSOpenPanel *panel = [NSOpenPanel openPanel];
  panel.allowedContentTypes = @[UTTypeApplicationBundle];
  panel.directoryURL = [NSURL fileURLWithPath:@"/Applications"];
  panel.canChooseDirectories = NO;
  panel.allowsMultipleSelection = YES;
  panel.message = NSLocalizedString(@"DisabledAppsOpenPanelMessage", @"Open panel message for choosing disabled app");

  [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
    if (result != NSModalResponseOK) {
      return;
    }
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableSet<NSString *> *disabled = [NSMutableSet setWithArray:[defaults arrayForKey:@"DisabledApplications"] ?: @[]];
    NSSet<NSString *> *blacklisted = [NSSet setWithArray:[defaults arrayForKey:@"BlacklistedApplications"] ?: @[]];

    BOOL changed = NO;
    for (NSURL *url in panel.URLs) {
      NSBundle *bundle = [NSBundle bundleWithURL:url];
      NSString *bundleID = bundle.bundleIdentifier;
      if (bundleID.length > 0 && ![blacklisted containsObject:bundleID] && ![disabled containsObject:bundleID]) {
        [disabled addObject:bundleID];
        changed = YES;
      }
    }
    if (changed) {
      [defaults setObject:disabled.allObjects forKey:@"DisabledApplications"];
      [[NSNotificationCenter defaultCenter] postNotificationName:SpectacleDisabledApplicationsDidChangeNotification object:self];
      [self reloadDisabledAppsList];
    }
  }];
}

- (void)removeDisabledApplicationAtIndex:(NSInteger)row
{
  if (row < 0 || row >= (NSInteger)_appListEntries.count) {
    return;
  }
  SpectacleAppListEntry *entry = _appListEntries[row];
  if (entry.isBuiltIn) {
    return;
  }

  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  NSMutableArray<NSString *> *disabled = [[defaults arrayForKey:@"DisabledApplications"] mutableCopy] ?: [NSMutableArray new];
  [disabled removeObject:entry.bundleIdentifier];
  [defaults setObject:disabled forKey:@"DisabledApplications"];
  [[NSNotificationCenter defaultCenter] postNotificationName:SpectacleDisabledApplicationsDidChangeNotification object:self];
  [self reloadDisabledAppsList];
}

- (IBAction)removeSelectedDisabledApplication:(id)sender
{
  [self removeDisabledApplicationAtIndex:_disabledAppsTableView.selectedRow];
}

- (IBAction)removeInlineDisabledApplication:(NSButton *)sender
{
  [self removeDisabledApplicationAtIndex:sender.tag];
}

#pragma mark - Actions: Accessibility Banner

- (IBAction)openAccessibilitySettings:(id)sender
{
  NSURL *url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"];
  [[NSWorkspace sharedWorkspace] openURL:url];
}

@end
