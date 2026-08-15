#import <Cocoa/Cocoa.h>
#import "AppDelegate.h"

// The delegate used to be instantiated and connected by MainMenu.xib. Doing it
// here instead means the app needs no nib at all, which is what lets the whole
// thing build with the Command Line Tools (ibtool ships only with Xcode). This
// is an LSUIElement tool, so the menu bar the nib carried was never shown.
int main(int argc, char *argv[])
{
  @autoreleasepool {
    NSApplication *application = [NSApplication sharedApplication];
    AppDelegate *delegate = [[AppDelegate alloc] init];
    application.delegate = delegate;
    [application run];
  }
  return 0;
}
