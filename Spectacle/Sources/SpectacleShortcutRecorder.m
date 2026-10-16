#import "SpectacleShortcutRecorder.h"

#import <Carbon/Carbon.h>

#import "SpectacleShortcut.h"
#import "SpectacleShortcutRecorderDelegate.h"
#import "SpectacleShortcutValidation.h"

@interface SpectacleShortcutRecorder ()

@property (nonatomic, strong) NSTextField *label;
@property (nonatomic, strong) NSButton *clearButton;
@property (nonatomic, assign) BOOL isRecording;

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
  self.layer.cornerRadius = 6.0;
  self.layer.borderWidth = 1.0;
  self.layer.borderColor = [NSColor separatorColor].CGColor;
  self.layer.backgroundColor = [NSColor controlBackgroundColor].CGColor;

  _label = [NSTextField labelWithString:@"Click to record"];
  _label.font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
  _label.lineBreakMode = NSLineBreakByTruncatingMiddle;
  _label.alignment = NSTextAlignmentCenter;
  _label.translatesAutoresizingMaskIntoConstraints = NO;
  [self addSubview:_label];

  _clearButton = [NSButton buttonWithTitle:@"×" target:self action:@selector(clearShortcut:)];
  _clearButton.bordered = NO;
  _clearButton.font = [NSFont systemFontOfSize:14.0];
  _clearButton.translatesAutoresizingMaskIntoConstraints = NO;
  _clearButton.hidden = YES;
  _clearButton.toolTip = @"Clear shortcut";
  [self addSubview:_clearButton];

  [NSLayoutConstraint activateConstraints:@[
    [_label.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:8.0],
    [_label.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-28.0],
    [_label.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],

    [_clearButton.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-2.0],
    [_clearButton.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    [_clearButton.widthAnchor constraintEqualToConstant:22.0],
  ]];
}

- (BOOL)acceptsFirstResponder
{
  return YES;
}

- (void)setShortcut:(SpectacleShortcut *)shortcut
{
  _shortcut = shortcut;
  [self updateDisplay];
}

- (void)updateDisplay
{
  if (_isRecording) {
    _label.stringValue = @"Type shortcut…";
  } else if (_shortcut && ![_shortcut isClearedShortcut]) {
    _label.stringValue = _shortcut.displayString;
  } else {
    _label.stringValue = @"Click to record";
  }

  _clearButton.hidden = (_isRecording || !_shortcut || [_shortcut isClearedShortcut]);
}

- (void)startRecording
{
  _isRecording = YES;
  self.layer.borderColor = [NSColor controlAccentColor].CGColor;
  [self updateDisplay];
}

- (void)stopRecording
{
  _isRecording = NO;
  self.layer.borderColor = [NSColor separatorColor].CGColor;
  [self updateDisplay];
}

- (void)mouseDown:(NSEvent *)event
{
  [self.window makeFirstResponder:self];
  [self startRecording];
}

- (void)keyDown:(NSEvent *)event
{
  if (!_isRecording) {
    [super keyDown:event];
    return;
  }

  if (event.keyCode == kVK_Escape) {
    [self stopRecording];
    return;
  }

  NSEventModifierFlags modifiers = event.modifierFlags
    & (NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagShift | NSEventModifierFlagCommand);

  SpectacleShortcut *shortcut = [[SpectacleShortcut alloc] initWithShortcutName:_shortcutName
                                                                shortcutKeyCode:event.keyCode
                                                              shortcutModifiers:modifiers];

  NSError *error = nil;
  if ([_shortcutValidation isShortcutValid:shortcut error:&error]) {
    _shortcut = shortcut;
    [_delegate shortcutRecorder:self didReceiveNewShortcut:shortcut];
  } else if (error) {
    [[NSAlert alertWithError:error] runModal];
  }

  [self stopRecording];
}

- (void)flagsChanged:(NSEvent *)event
{
  if (_isRecording) {
    [self setNeedsDisplay:YES];
  }
}

- (void)clearShortcut:(id)sender
{
  SpectacleShortcut *shortcut = _shortcut;
  _shortcut = nil;
  [_delegate shortcutRecorder:self didClearExistingShortcut:shortcut];
  [self updateDisplay];
}

@end
