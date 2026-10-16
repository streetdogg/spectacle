#import <Cocoa/Cocoa.h>

#import "SpectacleAppDelegate.h"

int main(int argc, char *argv[])
{
  @autoreleasepool {
    NSApplication *application = [NSApplication sharedApplication];
    SpectacleAppDelegate *appDelegate = [SpectacleAppDelegate new];
    application.delegate = appDelegate;
    [application run];
  }

  return 0;
}
