#import "SpectacleShortcutRecorder.h"

#import <Carbon/Carbon.h>
#import <QuartzCore/QuartzCore.h>

#import "SpectacleShortcut.h"
#import "SpectacleShortcutRecorderDelegate.h"
#import "SpectacleShortcutTranslations.h"
#import "SpectacleShortcutValidation.h"

@interface SpectacleShortcutRecorder ()

@property (nonatomic, strong) NSButton *clearButton;
@property (nonatomic, strong) NSTrackingArea *trackingArea;
@property (nonatomic, strong) NSPopover *errorPopover;
@property (nonatomic, copy) dispatch_block_t errorResetWorkItem;
@property (nonatomic, copy) NSString *liveModifierString;
@property (nonatomic, assign) BOOL isRecording;
@property (nonatomic, assign) BOOL isHovered;
@property (nonatomic, assign) BOOL isFocused;
@property (nonatomic, assign) BOOL isShowingError;

@end

@implementation SpectacleShortcutRecorder

- (instancetype)initWithFrame:(NSRect)frame
{
  if (self = [super initWithFrame:frame]) {
    [self configureView];
  }
  return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
  if (self = [super initWithCoder:coder]) {
    [self configureView];
  }
  return self;
}

- (void)configureView
{
  self.wantsLayer = YES;

  NSImage *clearImage = [NSImage imageWithSystemSymbolName:@"xmark.circle.fill"
                                  accessibilityDescription:NSLocalizedString(@"ShortcutRecorderClearTooltip", @"Clear shortcut tooltip")];
  NSImageSymbolConfiguration *symbolConfig = [NSImageSymbolConfiguration configurationWithPointSize:13.0
                                                                                             weight:NSFontWeightRegular];
  _clearButton = [NSButton buttonWithImage:[clearImage imageWithSymbolConfiguration:symbolConfig]
                                    target:self
                                    action:@selector(clearShortcut:)];
  _clearButton.bordered = NO;
  _clearButton.contentTintColor = [NSColor tertiaryLabelColor];
  _clearButton.translatesAutoresizingMaskIntoConstraints = NO;
  _clearButton.hidden = YES;
  _clearButton.toolTip = NSLocalizedString(@"ShortcutRecorderClearTooltip", @"Clear shortcut tooltip");
  [self addSubview:_clearButton];

  [NSLayoutConstraint activateConstraints:@[
    [_clearButton.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:0.0],
    [_clearButton.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    [_clearButton.widthAnchor constraintEqualToConstant:18.0],
    [_clearButton.heightAnchor constraintEqualToConstant:18.0],
  ]];

  [self updateDisplay];
}

#pragma mark - Drawing

- (NSArray<NSString *> *)keycapStringsForShortcut:(SpectacleShortcut *)shortcut
{
  if (!shortcut || [shortcut isClearedShortcut]) {
    return @[];
  }
  NSMutableArray<NSString *> *keys = [NSMutableArray new];
  NSString *modifiers = SpectacleTranslateModifiers(shortcut.shortcutModifiers);
  for (NSUInteger i = 0; i < modifiers.length; i++) {
    [keys addObject:[modifiers substringWithRange:NSMakeRange(i, 1)]];
  }
  NSString *keyString = SpectacleTranslateKeyCode(shortcut.shortcutKeyCode);
  if (keyString.length > 0) {
    [keys addObject:keyString];
  }
  return keys;
}

- (void)drawRect:(NSRect)dirtyRect
{
  [super drawRect:dirtyRect];

  BOOL hasShortcut = (_shortcut && ![_shortcut isClearedShortcut]);

  if (_isShowingError) {
    NSRect rect = NSInsetRect(self.bounds, 1.0, 1.0);
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:7.0 yRadius:7.0];
    path.lineWidth = 1.5;
    [[[NSColor systemRedColor] colorWithAlphaComponent:0.12] setFill];
    [path fill];
    [[NSColor systemRedColor] setStroke];
    [path stroke];
    if (hasShortcut) {
      [self drawKeycaps:[self keycapStringsForShortcut:_shortcut] highlighted:NO];
    } else {
      [self drawCenteredText:NSLocalizedString(@"ShortcutRecorderLabelClickToRecord", @"Placeholder")
                        font:[NSFont systemFontOfSize:11.5]
                       color:[NSColor systemRedColor]];
    }
    return;
  }

  if (_isRecording) {
    NSRect rect = NSInsetRect(self.bounds, 1.0, 1.0);
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:7.0 yRadius:7.0];
    path.lineWidth = 1.5;
    [[[NSColor controlAccentColor] colorWithAlphaComponent:0.12] setFill];
    [path fill];
    [[NSColor controlAccentColor] setStroke];
    [path stroke];

    NSString *text = _liveModifierString.length > 0
      ? _liveModifierString
      : NSLocalizedString(@"ShortcutRecorderLabelEnterShortcut", @"Prompt while recording a shortcut");
    NSColor *color = _liveModifierString.length > 0 ? [NSColor labelColor] : [NSColor controlAccentColor];
    [self drawCenteredText:text
                      font:[NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium]
                     color:color];
    return;
  }

  if (!hasShortcut) {
    NSRect rect = NSInsetRect(self.bounds, 0.75, 0.75);
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:7.0 yRadius:7.0];
    [[[NSColor labelColor] colorWithAlphaComponent:(_isHovered ? 0.06 : 0.03)] setFill];
    [path fill];

    if (_isFocused) {
      path.lineWidth = 1.5;
      [[[NSColor controlAccentColor] colorWithAlphaComponent:0.80] setStroke];
    } else {
      path.lineWidth = 0.75;
      CGFloat dash[2] = {3.0, 2.5};
      [path setLineDash:dash count:2 phase:0.0];
      [[[NSColor separatorColor] colorWithAlphaComponent:(_isHovered ? 1.0 : 0.75)] setStroke];
    }
    [path stroke];

    [self drawCenteredText:NSLocalizedString(@"ShortcutRecorderLabelClickToRecord", @"Placeholder when shortcut is not set")
                      font:[NSFont systemFontOfSize:11.5]
                     color:[NSColor placeholderTextColor]];
    return;
  }

  [self drawKeycaps:[self keycapStringsForShortcut:_shortcut] highlighted:_isHovered];
}

- (void)drawCenteredText:(NSString *)text font:(NSFont *)font color:(NSColor *)color
{
  NSDictionary *attrs = @{
    NSFontAttributeName: font,
    NSForegroundColorAttributeName: color,
  };
  NSSize sz = [text sizeWithAttributes:attrs];
  NSPoint pt = NSMakePoint(floor((self.bounds.size.width - sz.width) / 2.0),
                           floor((self.bounds.size.height - sz.height) / 2.0));
  [text drawAtPoint:pt withAttributes:attrs];
}

- (void)drawKeycaps:(NSArray<NSString *> *)keys highlighted:(BOOL)highlighted
{
  CGFloat clearButtonArea = 22.0;
  CGFloat x = self.bounds.size.width - clearButtonArea;
  CGFloat chipHeight = 22.0;
  CGFloat chipY = floor((self.bounds.size.height - chipHeight) / 2.0);
  CGFloat gap = 4.0;

  NSDictionary *attrs = @{
    NSFontAttributeName: [NSFont systemFontOfSize:12.0 weight:NSFontWeightMedium],
    NSForegroundColorAttributeName: [NSColor labelColor],
  };

  NSColor *fillColor = [[NSColor labelColor] colorWithAlphaComponent:(highlighted ? 0.10 : 0.06)];
  NSColor *strokeColor = _isFocused
    ? [[NSColor controlAccentColor] colorWithAlphaComponent:0.75]
    : [[NSColor labelColor] colorWithAlphaComponent:(highlighted ? 0.24 : 0.15)];
  CGFloat strokeWidth = _isFocused ? 1.0 : 0.75;

  for (NSInteger i = (NSInteger)keys.count - 1; i >= 0; i--) {
    NSString *key = keys[i];
    NSSize textSize = [key sizeWithAttributes:attrs];
    CGFloat chipWidth = MAX(22.0, ceil(textSize.width) + 11.0);
    x -= chipWidth;

    NSRect chipRect = NSMakeRect(x, chipY, chipWidth, chipHeight);
    NSBezierPath *chipPath = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(chipRect, 0.5, 0.5)
                                                             xRadius:5.5
                                                             yRadius:5.5];
    chipPath.lineWidth = strokeWidth;
    [fillColor setFill];
    [chipPath fill];
    [strokeColor setStroke];
    [chipPath stroke];

    NSPoint textOrigin = NSMakePoint(chipRect.origin.x + floor((chipWidth - textSize.width) / 2.0),
                                     chipRect.origin.y + floor((chipHeight - textSize.height) / 2.0));
    [key drawAtPoint:textOrigin withAttributes:attrs];

    x -= gap;
  }
}

#pragma mark - Tracking & Cursor

- (void)updateTrackingAreas
{
  [super updateTrackingAreas];
  if (_trackingArea) {
    [self removeTrackingArea:_trackingArea];
  }
  NSTrackingAreaOptions options = (NSTrackingMouseEnteredAndExited |
                                   NSTrackingActiveInKeyWindow |
                                   NSTrackingInVisibleRect);
  _trackingArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:options owner:self userInfo:nil];
  [self addTrackingArea:_trackingArea];
}

- (void)resetCursorRects
{
  [super resetCursorRects];
  [self addCursorRect:self.bounds cursor:[NSCursor pointingHandCursor]];
}

- (void)mouseEntered:(NSEvent *)event
{
  _isHovered = YES;
  _clearButton.contentTintColor = [NSColor secondaryLabelColor];
  [self setNeedsDisplay:YES];
}

- (void)mouseExited:(NSEvent *)event
{
  _isHovered = NO;
  _clearButton.contentTintColor = [NSColor tertiaryLabelColor];
  [self setNeedsDisplay:YES];
}

#pragma mark - First Responder & Appearance

- (BOOL)acceptsFirstResponder
{
  return YES;
}

- (BOOL)becomeFirstResponder
{
  BOOL result = [super becomeFirstResponder];
  if (result) {
    _isFocused = YES;
    [self setNeedsDisplay:YES];
  }
  return result;
}

- (BOOL)resignFirstResponder
{
  _isFocused = NO;
  if (_isRecording) {
    [self stopRecording];
  }
  [self setNeedsDisplay:YES];
  return [super resignFirstResponder];
}

- (void)viewDidChangeEffectiveAppearance
{
  [super viewDidChangeEffectiveAppearance];
  [self setNeedsDisplay:YES];
}

#pragma mark - Display

- (void)setShortcut:(SpectacleShortcut *)shortcut
{
  _shortcut = shortcut;
  [self updateDisplay];
}

- (void)updateDisplay
{
  BOOL hasShortcut = (_shortcut && ![_shortcut isClearedShortcut]);
  _clearButton.hidden = (_isRecording || !hasShortcut);
  [self setNeedsDisplay:YES];
}

#pragma mark - Recording Lifecycle

- (void)startRecording
{
  if (_isRecording) {
    return;
  }
  [self clearErrorState];
  _isRecording = YES;
  _liveModifierString = nil;
  if ([_delegate respondsToSelector:@selector(shortcutRecorderDidStartRecording:)]) {
    [_delegate shortcutRecorderDidStartRecording:self];
  }
  [self updateDisplay];
}

- (void)stopRecording
{
  if (!_isRecording) {
    return;
  }
  _isRecording = NO;
  _liveModifierString = nil;
  if ([_delegate respondsToSelector:@selector(shortcutRecorderDidStopRecording:)]) {
    [_delegate shortcutRecorderDidStopRecording:self];
  }
  [self updateDisplay];
}

#pragma mark - Mouse & Keyboard Events

- (void)mouseDown:(NSEvent *)event
{
  if (_isRecording) {
    [self stopRecording];
    return;
  }
  [self.window makeFirstResponder:self];
  [self startRecording];
}

- (void)keyDown:(NSEvent *)event
{
  if (!_isRecording) {
    if (event.keyCode == kVK_Space || event.keyCode == kVK_Return || event.keyCode == kVK_ANSI_KeypadEnter) {
      [self startRecording];
      return;
    }
    if (event.keyCode == kVK_Delete || event.keyCode == kVK_ForwardDelete) {
      if (_shortcut && ![_shortcut isClearedShortcut]) {
        [self clearShortcut:self];
      }
      return;
    }
    [super keyDown:event];
    return;
  }

  if (event.keyCode == kVK_Escape) {
    [self stopRecording];
    return;
  }

  NSEventModifierFlags modifiers = event.modifierFlags
    & (NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagShift | NSEventModifierFlagCommand);

  if (modifiers == 0 && (event.keyCode == kVK_Delete || event.keyCode == kVK_ForwardDelete)) {
    if (_shortcut && ![_shortcut isClearedShortcut]) {
      [self clearShortcut:self];
    }
    [self stopRecording];
    return;
  }

  if (![SpectacleShortcut validCocoaModifiers:modifiers]) {
    NSBeep();
    [self playShakeAnimation];
    return;
  }

  SpectacleShortcut *shortcut = [[SpectacleShortcut alloc] initWithShortcutName:_shortcutName
                                                                shortcutKeyCode:event.keyCode
                                                              shortcutModifiers:modifiers];

  NSError *error = nil;
  if ([_shortcutValidation isShortcutValid:shortcut error:&error]) {
    _shortcut = shortcut;
    [_delegate shortcutRecorder:self didReceiveNewShortcut:shortcut];
    [self stopRecording];
  } else {
    [self stopRecording];
    if (error) {
      [self showInlineValidationError:error];
    }
  }
}

- (void)flagsChanged:(NSEvent *)event
{
  if (!_isRecording) {
    return;
  }
  NSEventModifierFlags modifiers = event.modifierFlags
    & (NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagShift | NSEventModifierFlagCommand);
  NSString *modifierString = SpectacleTranslateModifiers(modifiers);
  _liveModifierString = modifierString.length > 0 ? modifierString : nil;
  [self setNeedsDisplay:YES];
}

#pragma mark - Context Menu

- (NSMenu *)menuForEvent:(NSEvent *)event
{
  NSMenu *menu = [NSMenu new];
  menu.autoenablesItems = NO;

  NSMenuItem *resetItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"ShortcutRecorderMenuResetToDefault", @"Reset single shortcut to default")
                                                     action:@selector(resetShortcutToDefault:)
                                              keyEquivalent:@""];
  resetItem.target = self;
  resetItem.enabled = [_delegate respondsToSelector:@selector(shortcutRecorderDidRequestResetToDefault:)];
  [menu addItem:resetItem];

  NSMenuItem *clearItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"ShortcutRecorderMenuClear", @"Clear single shortcut")
                                                     action:@selector(clearShortcut:)
                                              keyEquivalent:@""];
  clearItem.target = self;
  clearItem.enabled = (_shortcut && ![_shortcut isClearedShortcut]);
  [menu addItem:clearItem];

  return menu;
}

- (void)resetShortcutToDefault:(id)sender
{
  if (_isRecording) {
    [self stopRecording];
  }
  if ([_delegate respondsToSelector:@selector(shortcutRecorderDidRequestResetToDefault:)]) {
    [_delegate shortcutRecorderDidRequestResetToDefault:self];
  }
}

- (void)clearShortcut:(id)sender
{
  SpectacleShortcut *shortcut = _shortcut;
  _shortcut = nil;
  [_delegate shortcutRecorder:self didClearExistingShortcut:shortcut];
  [self updateDisplay];
}

#pragma mark - Inline Validation Feedback

- (void)clearErrorState
{
  if (_errorResetWorkItem) {
    dispatch_block_cancel(_errorResetWorkItem);
    _errorResetWorkItem = nil;
  }
  if (_errorPopover.isShown) {
    [_errorPopover close];
  }
  _isShowingError = NO;
  [self setNeedsDisplay:YES];
}

- (void)playShakeAnimation
{
  CAKeyframeAnimation *shake = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.x"];
  shake.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
  shake.duration = 0.28;
  shake.values = @[@(0), @(-5), @(5), @(-4), @(4), @(-2), @(2), @(0)];
  [self.layer addAnimation:shake forKey:@"shake"];
}

- (void)showInlineValidationError:(NSError *)error
{
  [self clearErrorState];
  NSBeep();

  _isShowingError = YES;
  [self setNeedsDisplay:YES];
  [self playShakeAnimation];

  NSString *title = error.localizedDescription ?: NSLocalizedString(@"AlertMessageTextShortcutValidationError", @"Validation error");
  NSString *detail = error.localizedRecoverySuggestion;

  NSTextField *titleLabel = [NSTextField wrappingLabelWithString:title];
  titleLabel.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightSemibold];
  titleLabel.textColor = [NSColor labelColor];
  titleLabel.preferredMaxLayoutWidth = 250.0;

  NSMutableArray<NSView *> *views = [NSMutableArray arrayWithObject:titleLabel];
  if (detail.length > 0) {
    NSTextField *detailLabel = [NSTextField wrappingLabelWithString:detail];
    detailLabel.font = [NSFont systemFontOfSize:11.0];
    detailLabel.textColor = [NSColor secondaryLabelColor];
    detailLabel.preferredMaxLayoutWidth = 250.0;
    [views addObject:detailLabel];
  }

  NSStackView *stack = [NSStackView stackViewWithViews:views];
  stack.orientation = NSUserInterfaceLayoutOrientationVertical;
  stack.alignment = NSLayoutAttributeLeading;
  stack.spacing = 4.0;
  stack.translatesAutoresizingMaskIntoConstraints = NO;

  NSView *container = [NSView new];
  [container addSubview:stack];
  [NSLayoutConstraint activateConstraints:@[
    [stack.topAnchor constraintEqualToAnchor:container.topAnchor constant:10.0],
    [stack.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-10.0],
    [stack.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:12.0],
    [stack.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-12.0],
  ]];

  NSViewController *contentController = [NSViewController new];
  contentController.view = container;

  _errorPopover = [NSPopover new];
  _errorPopover.behavior = NSPopoverBehaviorTransient;
  _errorPopover.contentViewController = contentController;
  [_errorPopover showRelativeToRect:self.bounds ofView:self preferredEdge:NSRectEdgeMaxY];

  __weak typeof(self) weakSelf = self;
  dispatch_block_t resetBlock = dispatch_block_create(0, ^{
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf) {
      return;
    }
    strongSelf.isShowingError = NO;
    [strongSelf setNeedsDisplay:YES];
  });
  _errorResetWorkItem = resetBlock;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), resetBlock);
}

#pragma mark - Accessibility

- (BOOL)isAccessibilityElement
{
  return YES;
}

- (NSAccessibilityRole)accessibilityRole
{
  return NSAccessibilityButtonRole;
}

- (NSString *)accessibilityLabel
{
  return _actionTitle ?: _shortcutName;
}

- (id)accessibilityValue
{
  if (_isRecording) {
    return NSLocalizedString(@"ShortcutRecorderLabelEnterShortcut", @"Prompt while recording a shortcut");
  }
  if (_shortcut && ![_shortcut isClearedShortcut]) {
    return _shortcut.displayString;
  }
  return NSLocalizedString(@"ShortcutRecorderAccessibilityUnassigned", @"Unassigned shortcut accessibility value");
}

- (BOOL)accessibilityPerformPress
{
  if (_isRecording) {
    [self stopRecording];
  } else {
    [self.window makeFirstResponder:self];
    [self startRecording];
  }
  return YES;
}

@end
