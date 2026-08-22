#import "AppDelegate.h"
#import <UserNotifications/UserNotifications.h>

// Exit codes. Distinct values so callers can tell "you asked for the
// impossible" apart from "the system would not let me".
static const int TNExitSuccess        = 0;
static const int TNExitUsage          = 1;
static const int TNExitBadArgument    = 2;
static const int TNExitNotAuthorized  = 3;
static const int TNExitTimeout        = 4;
static const int TNExitDeliveryFailed = 5;
static const int TNExitNoResponse     = 6;

// Nothing in this tool should ever take this long. Without a watchdog an
// invocation with no GUI session (over SSH, or from launchd as root) hangs
// forever with no output at all.
static const NSTimeInterval TNTimeoutSeconds = 10.0;

// Printed on stdout when an interactive notification resolves, so a caller can
// branch on the outcome. These spellings match what the 1.7-era builds and
// alerter emit, which is what TerminalNotifier.notify_result already parses.
static NSString * const TNResponseTimeout   = @"@TIMEOUT";
static NSString * const TNResponseClosed    = @"@CLOSED";
static NSString * const TNResponseClicked   = @"@ACTIONCLICKED";
static NSString * const TNCategoryIdentifier = @"fr.julienxx.oss.terminal-notifier.actions";
static NSString * const TNReplyActionIdentifier = @"reply";

// When the user clicks a notification, macOS relaunches this bundle with no
// arguments and delivers the response *after* applicationDidFinishLaunching
// returns. Verified on macOS 26. So an argument-less launch has to linger
// briefly instead of exiting, or -open/-execute/-activate never run.
static const NSTimeInterval TNResponseGraceSeconds = 5.0;

// Diagnostics go to stderr so that whoever ran the command actually sees them.
// NSLog is reserved for the click-activation audit trail, which the README
// documents as being readable in Console.app.
static void TNError(NSString *format, ...)
{
  va_list args;
  va_start(args, format);
  NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
  va_end(args);
  fprintf(stderr, "%s\n", [message UTF8String]);
}

@implementation NSUserDefaults (SubscriptAndUnescape)
- (id)objectForKeyedSubscript:(id)key;
{
  id obj = [self objectForKey:key];
  if ([obj isKindOfClass:[NSString class]] && [(NSString *)obj hasPrefix:@"\\"]) {
    obj = [(NSString *)obj substringFromIndex:1];
  }
  return obj;
}
@end

// -list output is tab separated and newline delimited, so a tab or newline
// inside a title or message silently corrupts the whole table. Collapse them to
// spaces: one row per notification matters more than reproducing the text byte
// for byte.
static NSString *TNSanitizeField(NSString *value)
{
  if (value == nil) return @"";

  NSString *result = value;
  for (NSString *character in @[@"\t", @"\n", @"\r"]) {
    result = [result stringByReplacingOccurrencesOfString:character withString:@" "];
  }
  return result;
}

static NSString *TNAuthorizationStatusName(UNAuthorizationStatus status)
{
  switch (status) {
    case UNAuthorizationStatusNotDetermined: return @"not requested yet";
    case UNAuthorizationStatusDenied:        return @"denied";
    case UNAuthorizationStatusAuthorized:    return @"authorized";
    case UNAuthorizationStatusProvisional:   return @"provisional";
    default:                                 return @"unknown";
  }
}

static NSString *TNSettingName(UNNotificationSetting setting)
{
  switch (setting) {
    case UNNotificationSettingNotSupported: return @"not supported";
    case UNNotificationSettingDisabled:     return @"disabled";
    case UNNotificationSettingEnabled:      return @"enabled";
    default:                                return @"unknown";
  }
}

static NSString *TNAlertStyleName(UNAlertStyle style)
{
  switch (style) {
    case UNAlertStyleNone:   return @"none";
    case UNAlertStyleBanner: return @"banners";
    case UNAlertStyleAlert:  return @"alerts (stay until dismissed)";
    default:                 return @"unknown";
  }
}

static NSString *TNPreviewsName(UNShowPreviewsSetting setting)
{
  switch (setting) {
    case UNShowPreviewsSettingAlways:           return @"always";
    case UNShowPreviewsSettingWhenAuthenticated: return @"when unlocked";
    case UNShowPreviewsSettingNever:            return @"never";
    default:                                    return @"unknown";
  }
}

@interface AppDelegate ()
@property (nonatomic) BOOL launchedFromNotification;
@property (nonatomic) BOOL awaitingAuthorization;
@property (nonatomic) BOOL awaitingResponse;
@end

@implementation AppDelegate

- (void)printHelpBanner;
{
  const char *appName = [[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleExecutable"] UTF8String];
  const char *appVersion = [[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] UTF8String];
  printf("%s (%s) is a command-line tool to send macOS User Notifications.\n" \
         "\n" \
         "Usage: %s -[message|list|remove] [VALUE|ID|ID] [options]\n" \
         "\n" \
         "   Either of these is required (unless message data is piped to the tool):\n" \
         "\n" \
         "       -help              Display this help banner.\n" \
         "       -version           Display terminal-notifier version.\n" \
         "       -diagnose          Report why notifications may not be appearing, and exit.\n" \
         "       -message VALUE     The notification message.\n" \
         "       -remove ID         Removes a notification with the specified ‘group’ ID.\n" \
         "       -list ID           If the specified ‘group’ ID exists show when it was delivered,\n" \
         "                          or use ‘ALL’ as ID to see all notifications.\n" \
         "                          The output is a tab-separated list.\n"
         "\n" \
         "   Optional:\n" \
         "\n" \
         "       -title VALUE       The notification title. Defaults to ‘Terminal’.\n" \
         "       -subtitle VALUE    The notification subtitle.\n" \
         "       -sound NAME        The name of a sound to play when the notification appears. The names are listed\n" \
         "                          in /System/Library/Sounds. Use 'default' for the default notification sound.\n" \
         "       -group ID          A string which identifies the group the notifications belong to.\n" \
         "                          Old notifications with the same ID will be removed.\n" \
         "       -activate ID       The bundle identifier of the application to activate when the user clicks the notification.\n" \
         "       -contentImage PATH The path of an image to attach to the notification. Local files only.\n" \
         "       -open URL          The URL of a resource to open when the user clicks the notification.\n" \
         "       -execute COMMAND   A shell command to perform when the user clicks the notification.\n" \
         "       -action TITLE      Add an action button. Repeat the option, or pass a comma separated\n" \
         "                          list, for several. Waits for a response and prints the chosen title.\n" \
         "       -reply [PROMPT]    Add a text field to the notification. Waits and prints what was typed.\n" \
         "       -timeout SECONDS   How long to wait for a response to -action or -reply. Defaults to\n" \
         "                          waiting indefinitely. Prints @TIMEOUT and exits 6 if it expires.\n" \
         "       -ignoreDnD         Request delivery even when Do Not Disturb is enabled. Best effort only:\n" \
         "                          this needs an Apple-granted entitlement that this build does not carry,\n" \
         "                          so it is usually a no-op. See the README.\n" \
         "\n" \
         "   Removed:\n" \
         "\n" \
         "       -sender ID         No longer supported. It worked by overriding this tool's own bundle\n" \
         "                          identifier, which the UserNotifications framework does not permit.\n" \
         "       -appIcon URL       No longer supported. macOS has no API to override a notification's icon;\n" \
         "                          the icon always comes from the app bundle. See the README for the\n" \
         "                          custom-bundle workaround.\n" \
         "\n" \
         "With -action or -reply the outcome is printed on stdout: the button title, the text\n" \
         "that was typed, or one of @ACTIONCLICKED, @CLOSED or @TIMEOUT.\n" \
         "\n" \
         "What -open, -execute and -activate did is written to the system log instead. Read it\n" \
         "with Console.app, or:  log show --predicate 'process == \"terminal-notifier\"' --last 5m\n" \
         "\n" \
         "Note that in some circumstances the first character of a message has to be escaped in order to be recognized.\n" \
         "An example of this is when using an open bracket, which has to be escaped like so: ‘\\[’.\n" \
         "\n" \
         "For more information see https://github.com/julienXX/terminal-notifier.\n",
         appName, appVersion, appName);
}

- (void)printVersion;
{
  const char *appName = [[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleExecutable"] UTF8String];
  const char *appVersion = [[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] UTF8String];
  printf("%s %s.\n", appName, appVersion);
}

// Reports everything that decides whether a notification actually shows up.
// Most "terminal-notifier stopped working" reports come down to one of these
// rows, and none of them were previously observable from the command line.
- (void)printDiagnostics;
{
  NSBundle *bundle = [NSBundle mainBundle];

  printf("terminal-notifier %s\n",
         [[bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] UTF8String]);
  printf("  bundle id           %s\n", [[bundle bundleIdentifier] UTF8String]);
  printf("  bundle path         %s\n", [[bundle bundlePath] UTF8String]);
  printf("  macOS               %s\n",
         [[[NSProcessInfo processInfo] operatingSystemVersionString] UTF8String]);

  // A notification is attributed to a bundle identity, so an unsigned or
  // relocated bundle is a common cause of silent failure.
  BOOL notificationCentreRunning = NO;
  for (NSRunningApplication *app in [[NSWorkspace sharedWorkspace] runningApplications]) {
    if ([app.bundleIdentifier isEqualToString:@"com.apple.notificationcenterui"]) {
      notificationCentreRunning = YES;
      break;
    }
  }
  printf("  NotificationCenter  %s\n", notificationCentreRunning ? "running" : "NOT RUNNING");

  UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
  [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
    dispatch_async(dispatch_get_main_queue(), ^{
      printf("\n");
      printf("  authorization       %s\n", [TNAuthorizationStatusName(settings.authorizationStatus) UTF8String]);
      printf("  alerts              %s\n", [TNSettingName(settings.alertSetting) UTF8String]);
      printf("  alert style         %s\n", [TNAlertStyleName(settings.alertStyle) UTF8String]);
      printf("  sounds              %s\n", [TNSettingName(settings.soundSetting) UTF8String]);
      printf("  notification centre %s\n", [TNSettingName(settings.notificationCenterSetting) UTF8String]);
      printf("  lock screen         %s\n", [TNSettingName(settings.lockScreenSetting) UTF8String]);
      printf("  previews            %s\n", [TNPreviewsName(settings.showPreviewsSetting) UTF8String]);
      printf("  critical alerts     %s\n", [TNSettingName(settings.criticalAlertSetting) UTF8String]);

      if (@available(macOS 12.0, *)) {
        printf("  time sensitive      %s\n", [TNSettingName(settings.timeSensitiveSetting) UTF8String]);
        // This is Scheduled Summary: notifications are held back and delivered
        // in a digest, which looks exactly like nothing happening.
        printf("  scheduled delivery  %s\n", [TNSettingName(settings.scheduledDeliverySetting) UTF8String]);
      }

      // Turn the rows above into advice, so a user does not have to know which
      // ones matter.
      NSMutableArray<NSString *> *problems = [NSMutableArray array];
      if (settings.authorizationStatus == UNAuthorizationStatusDenied) {
        [problems addObject:[NSString stringWithFormat:
          @"Notifications are turned off. Enable them in System Settings > Notifications,\n"
           "    or reset the permission with:\n"
           "      tccutil reset UserNotification %@\n"
           "    (the app bundle must still be installed for that command to resolve)",
          [bundle bundleIdentifier]]];
      }
      if (settings.authorizationStatus == UNAuthorizationStatusNotDetermined) {
        [problems addObject:@"Permission has never been requested. Send one notification and approve the prompt."];
      }
      if (settings.alertSetting == UNNotificationSettingDisabled) {
        [problems addObject:@"Alerts are disabled, so nothing will be shown on screen."];
      }
      if (settings.alertStyle == UNAlertStyleNone) {
        [problems addObject:@"Alert style is None. Set it to Banners or Alerts in System Settings > Notifications."];
      }
      if (settings.soundSetting == UNNotificationSettingDisabled) {
        [problems addObject:@"Sounds are disabled, so -sound will be silent."];
      }
      if (!notificationCentreRunning) {
        [problems addObject:@"NotificationCenter is not running. Try: killall NotificationCenter"];
      }
      if (@available(macOS 12.0, *)) {
        if (settings.scheduledDeliverySetting == UNNotificationSettingEnabled) {
          [problems addObject:@"Scheduled Summary is on, so notifications may be held back for a digest."];
        }
      }

      printf("\n");
      if (problems.count == 0) {
        printf("No problems found.\n");
      } else {
        printf("Problems found:\n");
        for (NSString *problem in problems) {
          printf("  - %s\n", [problem UTF8String]);
        }
      }

      exit(settings.authorizationStatus == UNAuthorizationStatusAuthorized ||
           settings.authorizationStatus == UNAuthorizationStatusProvisional
             ? TNExitSuccess : TNExitNotAuthorized);
    });
  }];
}

- (void)applicationWillFinishLaunching:(NSNotification *)notification;
{
  // Set the delegate before the app finishes launching, so that a response
  // arriving because the user clicked a notification is seen by us rather
  // than dropped on the floor.
  [UNUserNotificationCenter currentNotificationCenter].delegate = self;

  [self armWatchdog];
}

// The watchdog exists to turn a silent hang into a diagnosable failure, but it
// must not fire while the system permission dialog is waiting on a human.
- (void)armWatchdog;
{
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(TNTimeoutSeconds * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
    if (self.awaitingAuthorization || self.awaitingResponse) {
      [self armWatchdog];
      return;
    }
    TNError(@"Timed out after %.0f seconds waiting for the notification service.", TNTimeoutSeconds);
    TNError(@"This usually means no GUI session is available — for example when running over SSH,");
    TNError(@"or from launchd as root. Notifications can only be posted for a logged-in user.");
    exit(TNExitTimeout);
  });
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification;
{
  NSArray *arguments = [[NSProcessInfo processInfo] arguments];

  if ([arguments containsObject:@"-help"]) {
    [self printHelpBanner];
    exit(TNExitSuccess);
  }

  if ([arguments containsObject:@"-version"]) {
    [self printVersion];
    exit(TNExitSuccess);
  }

  if ([arguments containsObject:@"-diagnose"] || [arguments containsObject:@"--diagnose"]) {
    [self printDiagnostics];
    return; // exits from the completion handler
  }

  // We were launched by a notification click; the delegate callback handles
  // everything and exits.
  if (self.launchedFromNotification) return;

  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

  NSString *subtitle = defaults[@"subtitle"];
  NSString *message  = defaults[@"message"];
  NSString *remove   = defaults[@"remove"];
  NSString *list     = defaults[@"list"];
  NSString *sound    = defaults[@"sound"];
  NSString *title    = defaults[@"title"] ?: @"Terminal";

  // A -message that NSUserDefaults could not parse arrives as nil, which is
  // indistinguishable from "no -message given" unless we look at argv. Falling
  // through to the stdin read below would then block forever on an open pipe,
  // which is exactly what the Ruby wrapper hands us.
  if (message == nil && [arguments containsObject:@"-message"]) {
    TNError(@"Could not read the -message value.");
    TNError(@"If it begins with a character such as '[', '(', '{' or a quote, escape it:");
    TNError(@"  -message '\\[like this'");
    exit(TNExitBadArgument);
  }

  // If there is no message and data is piped to the application, use that
  // instead.
  //
  // Only when a message is actually needed: this read blocks until stdin sees
  // EOF, and because it runs on the main thread it also blocks the watchdog.
  // `-list`/`-remove` don't need a message, and reading stdin for them would
  // hang indefinitely whenever stdin is a pipe that stays open.
  if (message == nil && remove == nil && list == nil && !isatty(STDIN_FILENO)) {
    NSData *inputData = [[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile];
    message = [[NSString alloc] initWithData:inputData encoding:NSUTF8StringEncoding];
    // Drop the trailing newline a pipe almost always carries. Left in, it ends
    // up inside the body and splits the tab-separated -list row in two.
    while ([message hasSuffix:@"\n"] || [message hasSuffix:@"\r"]) {
      message = [message substringToIndex:message.length - 1];
    }
  }

  if (message == nil && remove == nil && list == nil) {
    [self printHelpBanner];
    exit(TNExitUsage);
  }

  // Options that no longer exist. Warn and carry on rather than failing, so
  // that existing scripts keep working instead of breaking outright.
  if (defaults[@"sender"]) {
    TNError(@"[!] -sender is no longer supported and will be ignored.");
    TNError(@"    It relied on overriding this tool's bundle identifier, which the");
    TNError(@"    UserNotifications framework does not allow.");
  }
  if (defaults[@"appIcon"]) {
    TNError(@"[!] -appIcon is no longer supported and will be ignored.");
    TNError(@"    macOS provides no API to override a notification's icon; it always");
    TNError(@"    comes from the app bundle. See the README for the workaround.");
  }

  if (list) {
    [self listNotificationWithGroupID:list];
    return; // exits from the completion handler
  }

  NSMutableDictionary *options = [NSMutableDictionary dictionary];
  if (defaults[@"activate"])     options[@"bundleID"]     = defaults[@"activate"];
  if (defaults[@"group"])        options[@"groupID"]      = defaults[@"group"];
  if (defaults[@"execute"])      options[@"command"]      = defaults[@"execute"];
  if (defaults[@"contentImage"]) options[@"contentImage"] = defaults[@"contentImage"];

  if (defaults[@"open"]) {
    NSURL *url = [NSURL URLWithString:defaults[@"open"]];
    if ((url && url.scheme && url.host) || [url isFileURL]) {
      options[@"open"] = defaults[@"open"];
    } else {
      TNError(@"'%@' is not a valid URI.", defaults[@"open"]);
      exit(TNExitBadArgument);
    }
  }

  if ([arguments containsObject:@"-ignoreDnD"]) {
    options[@"ignoreDnD"] = @YES;
  }

  // Action button titles: -action may be repeated, and each value may itself be
  // a comma separated list.
  NSMutableArray<NSString *> *actionTitles = [NSMutableArray array];
  for (NSUInteger i = 0; i + 1 < arguments.count; i++) {
    if (![arguments[i] isEqualToString:@"-action"]) continue;
    for (NSString *title in [arguments[i + 1] componentsSeparatedByString:@","]) {
      NSString *trimmed = [title stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceCharacterSet]];
      if (trimmed.length > 0) [actionTitles addObject:trimmed];
    }
  }
  if (actionTitles.count > 0) options[@"actions"] = actionTitles;

  // -reply works with or without a placeholder, so it is detected in argv
  // rather than through NSUserDefaults.
  if ([arguments containsObject:@"-reply"]) {
    options[@"reply"] = @YES;
    NSString *placeholder = defaults[@"reply"];
    if (placeholder != nil && ![placeholder hasPrefix:@"-"]) {
      options[@"replyPlaceholder"] = placeholder;
    }
  }

  if (defaults[@"timeout"]) {
    NSTimeInterval seconds = [defaults[@"timeout"] doubleValue];
    if (seconds <= 0) {
      TNError(@"-timeout expects a positive number of seconds.");
      exit(TNExitBadArgument);
    }
    options[@"timeout"] = @(seconds);
  }

  BOOL hasMessage = (message != nil && message.length > 0);

  if (remove) {
    // Removal is asynchronous. Delivery has to happen inside the completion
    // handler, otherwise a `-remove X -message Y -group X` invocation races
    // and can delete the notification it just posted.
    [self removeNotificationWithGroupID:remove completionHandler:^{
      if (!hasMessage) exit(TNExitSuccess);
      [self deliverNotificationWithTitle:title
                               subtitle:subtitle
                                message:message
                                options:options
                                  sound:sound];
    }];
    return;
  }

  if (hasMessage) {
    [self deliverNotificationWithTitle:title
                             subtitle:subtitle
                              message:message
                              options:options
                                sound:sound];
  } else if (arguments.count == 1) {
    // Nothing to do and nothing on the command line. An interactive run with
    // no arguments has already exited above (stdin is a tty then), so reaching
    // here most likely means macOS relaunched us to deliver a click.
    [self waitForNotificationResponse];
  } else {
    [self printHelpBanner];
    exit(TNExitUsage);
  }
}

- (void)waitForNotificationResponse;
{
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(TNResponseGraceSeconds * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
    if (self.launchedFromNotification) return; // handled; that path exits itself
    [self printHelpBanner];
    exit(TNExitUsage);
  });
}

- (NSURL *)localFileURLFromString:(NSString *)urlString;
{
  NSURL *url = [NSURL URLWithString:urlString];
  if ([[url scheme] length] == 0) {
    url = [NSURL fileURLWithPath:urlString];
  }
  return url;
}

// Resolve the current authorization state before trying to deliver, so that a
// refusal produces an actionable message rather than silence.
- (void)withAuthorization:(void (^)(void))block;
{
  UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];

  [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
    switch (settings.authorizationStatus) {
      case UNAuthorizationStatusAuthorized:
      case UNAuthorizationStatusProvisional:
        dispatch_async(dispatch_get_main_queue(), block);
        break;

      case UNAuthorizationStatusDenied:
        TNError(@"Notifications are turned off for this application.");
        TNError(@"Enable them in System Settings > Notifications, or reset the");
        TNError(@"permission so it can be asked for again:");
        TNError(@"  tccutil reset UserNotification %@", [[NSBundle mainBundle] bundleIdentifier]);
        exit(TNExitNotAuthorized);
        break;

      case UNAuthorizationStatusNotDetermined:
      default: {
        UNAuthorizationOptions opts = UNAuthorizationOptionAlert | UNAuthorizationOptionSound;
        // macOS is about to ask the user; the watchdog must stand down until
        // they answer.
        self.awaitingAuthorization = YES;
        [center requestAuthorizationWithOptions:opts
                              completionHandler:^(BOOL granted, NSError *error) {
          self.awaitingAuthorization = NO;
          if (error) {
            TNError(@"Could not request notification permission: %@", error.localizedDescription);
            exit(TNExitNotAuthorized);
          }
          if (!granted) {
            TNError(@"Permission to send notifications was declined.");
            TNError(@"Grant it in System Settings > Notifications, then try again.");
            exit(TNExitNotAuthorized);
          }
          dispatch_async(dispatch_get_main_queue(), block);
        }];
        break;
      }
    }
  }];
}

- (void)deliverNotificationWithTitle:(NSString *)title
                            subtitle:(NSString *)subtitle
                             message:(NSString *)message
                             options:(NSDictionary *)options
                               sound:(NSString *)sound;
{
  [self withAuthorization:^{
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];

    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    content.title = title;
    if (subtitle) content.subtitle = subtitle;
    content.body = message;

    if (sound != nil) {
      content.sound = [sound isEqualToString:@"default"]
        ? [UNNotificationSound defaultSound]
        : [UNNotificationSound soundNamed:sound];
    }

    NSString *groupID = options[@"groupID"];
    if (groupID) content.threadIdentifier = groupID;

    // Buttons and text fields only exist as part of a category, which has to be
    // registered with the centre before the request is added.
    NSArray<NSString *> *actionTitles = options[@"actions"];
    BOOL wantsReply = [options[@"reply"] boolValue];
    BOOL interactive = (actionTitles.count > 0 || wantsReply);

    if (interactive) {
      NSMutableArray<UNNotificationAction *> *actions = [NSMutableArray array];

      if (wantsReply) {
        NSString *placeholder = options[@"replyPlaceholder"] ?: @"";
        [actions addObject:
          [UNTextInputNotificationAction actionWithIdentifier:TNReplyActionIdentifier
                                                        title:@"Reply"
                                                      options:UNNotificationActionOptionNone
                                         textInputButtonTitle:@"Send"
                                         textInputPlaceholder:placeholder]];
      }

      // The identifier is the index, so the title can be recovered verbatim
      // from the notification's userInfo when the response comes back.
      [actionTitles enumerateObjectsUsingBlock:^(NSString *title, NSUInteger i, BOOL *stop) {
        [actions addObject:
          [UNNotificationAction actionWithIdentifier:[NSString stringWithFormat:@"action-%lu", (unsigned long)i]
                                               title:title
                                             options:UNNotificationActionOptionNone]];
      }];

      UNNotificationCategory *category =
        [UNNotificationCategory categoryWithIdentifier:TNCategoryIdentifier
                                              actions:actions
                                    intentIdentifiers:@[]
                                              options:UNNotificationCategoryOptionCustomDismissAction];
      [center setNotificationCategories:[NSSet setWithObject:category]];
      content.categoryIdentifier = TNCategoryIdentifier;
    }

    if (options[@"ignoreDnD"]) {
      if (@available(macOS 12.0, *)) {
        content.interruptionLevel = UNNotificationInterruptionLevelTimeSensitive;
      }
    }

    if (options[@"contentImage"]) {
      NSURL *imageURL = [self localFileURLFromString:options[@"contentImage"]];
      if (![imageURL isFileURL]) {
        TNError(@"[!] -contentImage only accepts local file paths.");
      } else if (![[NSFileManager defaultManager] fileExistsAtPath:[imageURL path]]) {
        // Check up front: the attachment object is created lazily, so an
        // unreadable path would otherwise fail the whole delivery rather than
        // just dropping the image.
        TNError(@"[!] Could not attach '%@': no such file.", options[@"contentImage"]);
      } else {
        // UNNotificationAttachment *moves* the file into the notification data
        // store, which would delete the caller's image. Hand it a throwaway
        // copy so the original survives.
        NSFileManager *files = [NSFileManager defaultManager];
        NSString *extension = [imageURL pathExtension];
        NSString *name = [NSString stringWithFormat:@"terminal-notifier-%@%@",
                          [[NSUUID UUID] UUIDString],
                          extension.length > 0 ? [@"." stringByAppendingString:extension] : @""];
        NSURL *copyURL = [NSURL fileURLWithPath:
                           [NSTemporaryDirectory() stringByAppendingPathComponent:name]];

        NSError *copyError = nil;
        if (![files copyItemAtURL:imageURL toURL:copyURL error:&copyError]) {
          TNError(@"[!] Could not attach '%@': %@",
                  options[@"contentImage"], copyError.localizedDescription);
        } else {
          NSError *attachError = nil;
          UNNotificationAttachment *attachment =
            [UNNotificationAttachment attachmentWithIdentifier:@"contentImage"
                                                          URL:copyURL
                                                      options:nil
                                                        error:&attachError];
          if (attachment) {
            content.attachments = @[attachment];
          } else {
            TNError(@"[!] Could not attach '%@': %@",
                    options[@"contentImage"], attachError.localizedDescription);
            // The copy was not consumed, so clean it up ourselves.
            [files removeItemAtURL:copyURL error:NULL];
          }
        }
      }
    }

    // Metadata the click handler needs when the app is relaunched.
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    if (options[@"bundleID"]) userInfo[@"bundleID"] = options[@"bundleID"];
    if (groupID)              userInfo[@"groupID"]  = groupID;
    if (options[@"command"])  userInfo[@"command"]  = options[@"command"];
    if (options[@"open"])     userInfo[@"open"]     = options[@"open"];
    if (actionTitles)         userInfo[@"actions"]  = actionTitles;
    content.userInfo = userInfo;

    // Reusing an identifier is what makes a notification replace an earlier
    // one, so it must only happen when the caller actually asked for a group.
    // Sharing one identifier across all ungrouped notifications would make
    // every new notification silently overwrite the previous one.
    NSString *identifier = groupID ?: [[NSUUID UUID] UUIDString];

    if (groupID) {
      [center removeDeliveredNotificationsWithIdentifiers:@[identifier]];
      [center removePendingNotificationRequestsWithIdentifiers:@[identifier]];
    }

    UNNotificationRequest *request =
      [UNNotificationRequest requestWithIdentifier:identifier
                                           content:content
                                           trigger:nil];

    [center addNotificationRequest:request withCompletionHandler:^(NSError *error) {
      if (error) {
        TNError(@"Failed to deliver notification: %@", error.localizedDescription);
        // Distinguish "you are not allowed" from "the request was bad", so a
        // caller can tell a permissions problem from a broken argument.
        if ([error.domain isEqualToString:UNErrorDomain] &&
            error.code == UNErrorCodeNotificationsNotAllowed) {
          TNError(@"Run with -diagnose to see why.");
          exit(TNExitNotAuthorized);
        }
        exit(TNExitDeliveryFailed);
      }
      if (interactive) {
        // A button or reply field is only useful if the caller can read what
        // the user chose, and stdout is still connected to them only while this
        // process lives. Exiting here would send the response to a relaunched
        // copy whose output goes nowhere.
        self.awaitingResponse = YES;

        NSNumber *timeout = options[@"timeout"];
        if (timeout != nil) {
          dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                       (int64_t)(timeout.doubleValue * NSEC_PER_SEC)),
                         dispatch_get_main_queue(), ^{
            [self reportResponse:TNResponseTimeout andExit:TNExitNoResponse];
          });
        }
        return;
      }

      // The request is handed off and persisted at this point; presentation and
      // sound are the notification service's job, not ours. There is nothing
      // left to wait for, so exit immediately rather than on a timer.
      exit(TNExitSuccess);
    }];
  }];
}

- (void)removeNotificationWithGroupID:(NSString *)groupID
                    completionHandler:(void (^)(void))completionHandler;
{
  UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];

  // Delivered, not pending: pending requests are ones that have not fired yet,
  // and this tool always delivers immediately.
  [center getDeliveredNotificationsWithCompletionHandler:^(NSArray<UNNotification *> *notifications) {
    NSMutableArray<NSString *> *identifiers = [NSMutableArray array];

    for (UNNotification *notification in notifications) {
      NSString *deliveredGroupID = notification.request.content.userInfo[@"groupID"];
      if ([@"ALL" isEqualToString:groupID] || [deliveredGroupID isEqualToString:groupID]) {
        printf("* Removing previously sent notification, which was sent on: %s\n",
               [[notification.date description] UTF8String]);
        [identifiers addObject:notification.request.identifier];
      }
    }

    if (identifiers.count > 0) {
      [center removeDeliveredNotificationsWithIdentifiers:identifiers];
    }

    dispatch_async(dispatch_get_main_queue(), ^{
      if (completionHandler) completionHandler();
    });
  }];
}

- (void)listNotificationWithGroupID:(NSString *)listGroupID;
{
  UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];

  [center getDeliveredNotificationsWithCompletionHandler:^(NSArray<UNNotification *> *notifications) {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];

    for (UNNotification *notification in notifications) {
      UNNotificationContent *content = notification.request.content;
      NSString *deliveredGroupID = content.userInfo[@"groupID"];

      if (![@"ALL" isEqualToString:listGroupID] && ![deliveredGroupID isEqualToString:listGroupID]) {
        continue;
      }

      // Empty fields rather than "(null)", so the output stays parseable.
      [lines addObject:[NSString stringWithFormat:@"%@\t%@\t%@\t%@\t%@",
                        TNSanitizeField(deliveredGroupID),
                        TNSanitizeField(content.title),
                        TNSanitizeField(content.subtitle),
                        TNSanitizeField(content.body),
                        TNSanitizeField([notification.date description])]];
    }

    dispatch_async(dispatch_get_main_queue(), ^{
      if (lines.count > 0) {
        printf("GroupID\tTitle\tSubtitle\tMessage\tDelivered At\n");
        for (NSString *line in lines) {
          printf("%s\n", [line UTF8String]);
        }
      }
      exit(TNExitSuccess);
    });
  }];
}

- (void)reportResponse:(NSString *)text andExit:(int)status;
{
  printf("%s\n", [text UTF8String]);
  fflush(stdout);
  exit(status);
}

// Maps a response on an interactive notification onto a single line of stdout.
// Returns NO when the notification was not interactive, so the caller falls
// through to the -open/-execute/-activate handling instead.
- (BOOL)reportInteractiveResponse:(UNNotificationResponse *)response;
{
  NSString *actionIdentifier = response.actionIdentifier;

  if ([response isKindOfClass:[UNTextInputNotificationResponse class]]) {
    [self reportResponse:[(UNTextInputNotificationResponse *)response userText]
                 andExit:TNExitSuccess];
    return YES;
  }

  if ([actionIdentifier isEqualToString:UNNotificationDismissActionIdentifier]) {
    [self reportResponse:TNResponseClosed andExit:TNExitSuccess];
    return YES;
  }

  if ([actionIdentifier hasPrefix:@"action-"]) {
    NSArray<NSString *> *titles = response.notification.request.content.userInfo[@"actions"];
    NSUInteger index = (NSUInteger)[[actionIdentifier substringFromIndex:7] integerValue];
    NSString *title = (index < titles.count) ? titles[index] : actionIdentifier;
    [self reportResponse:title andExit:TNExitSuccess];
    return YES;
  }

  // The body itself was clicked. Only meaningful as a reportable outcome when
  // the notification was interactive; otherwise it means "run the click action".
  if ([actionIdentifier isEqualToString:UNNotificationDefaultActionIdentifier] &&
      self.awaitingResponse) {
    NSDictionary *userInfo = response.notification.request.content.userInfo;
    BOOL hasClickAction = userInfo[@"bundleID"] || userInfo[@"command"] || userInfo[@"open"];
    if (!hasClickAction) {
      [self reportResponse:TNResponseClicked andExit:TNExitSuccess];
      return YES;
    }
  }

  return NO;
}

- (void)userActivatedNotification:(UNNotificationResponse *)response;
{
  if ([self reportInteractiveResponse:response]) return;

  self.launchedFromNotification = YES;

  UNNotificationContent *content = response.notification.request.content;
  NSDictionary *userInfo = content.userInfo;

  NSString *groupID  = userInfo[@"groupID"];
  NSString *bundleID = userInfo[@"bundleID"];
  NSString *command  = userInfo[@"command"];
  NSString *open     = userInfo[@"open"];

  [[UNUserNotificationCenter currentNotificationCenter]
    removeDeliveredNotificationsWithIdentifiers:@[response.notification.request.identifier]];

  NSLog(@"User activated notification:");
  NSLog(@" group ID: %@", groupID);
  NSLog(@"    title: %@", content.title);
  NSLog(@" subtitle: %@", content.subtitle);
  NSLog(@"  message: %@", content.body);
  NSLog(@"bundle ID: %@", bundleID);
  NSLog(@"  command: %@", command);
  NSLog(@"     open: %@", open);

  BOOL success = YES;
  if (bundleID) success &= [self activateAppWithBundleID:bundleID];
  if (command)  success &= [self executeShellCommand:command];
  if (open)     success &= [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:open]];

  exit(success ? TNExitSuccess : TNExitDeliveryFailed);
}

- (BOOL)activateAppWithBundleID:(NSString *)bundleID;
{
  // NSRunningApplication and NSWorkspace instead of ScriptingBridge: sending
  // Apple events needs an Automation TCC grant that this tool does not ask
  // for, so the ScriptingBridge path silently failed on modern macOS.
  NSArray<NSRunningApplication *> *running =
    [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleID];

  if (running.count > 0) {
    return [running.firstObject activateWithOptions:NSApplicationActivateIgnoringOtherApps];
  }

  NSWorkspace *workspace = [NSWorkspace sharedWorkspace];
  NSURL *appURL = [workspace URLForApplicationWithBundleIdentifier:bundleID];
  if (appURL == nil) {
    TNError(@"Unable to find an application with bundle identifier '%@'.", bundleID);
    return NO;
  }

  if (@available(macOS 11.0, *)) {
    NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
    configuration.activates = YES;
    [workspace openApplicationAtURL:appURL configuration:configuration completionHandler:nil];
    return YES;
  }
  return [workspace launchApplication:[appURL path]];
}

- (BOOL)executeShellCommand:(NSString *)command;
{
  NSPipe *pipe = [NSPipe pipe];

  NSTask *task = [NSTask new];
  task.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
  task.arguments = @[@"-c", command];
  task.standardOutput = pipe;
  task.standardError = pipe;

  NSError *launchError = nil;
  if (![task launchAndReturnError:&launchError]) {
    TNError(@"Failed to run command: %@", launchError.localizedDescription);
    return NO;
  }

  // Drain the pipe fully before waiting. The old loop polled availableData and
  // could deadlock once a chatty command filled the pipe buffer.
  NSData *output = [[pipe fileHandleForReading] readDataToEndOfFile];
  [task waitUntilExit];

  NSString *outputString = [[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding];
  NSLog(@"command output: %@", outputString);

  return [task terminationStatus] == 0;
}

#pragma mark - UNUserNotificationCenterDelegate

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler;
{
  UNNotificationPresentationOptions options;
  if (@available(macOS 11.0, *)) {
    options = UNNotificationPresentationOptionBanner
            | UNNotificationPresentationOptionList
            | UNNotificationPresentationOptionSound;
  } else {
    options = UNNotificationPresentationOptionAlert
            | UNNotificationPresentationOptionSound;
  }
  completionHandler(options);
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
didReceiveNotificationResponse:(UNNotificationResponse *)response
         withCompletionHandler:(void (^)(void))completionHandler;
{
  completionHandler();
  [self userActivatedNotification:response];
}

@end
