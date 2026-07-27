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

// Nothing in this tool should ever take this long. Without a watchdog an
// invocation with no GUI session (over SSH, or from launchd as root) hangs
// forever with no output at all.
static const NSTimeInterval TNTimeoutSeconds = 10.0;

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

@interface AppDelegate ()
@property (nonatomic) BOOL launchedFromNotification;
@property (nonatomic) BOOL awaitingAuthorization;
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
         "When the user activates a notification, the results are logged to the system logs.\n" \
         "Use Console.app to view these logs.\n" \
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
    if (self.awaitingAuthorization) {
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

  // If there is no message and data is piped to the application, use that
  // instead.
  if (message == nil && !isatty(STDIN_FILENO)) {
    NSData *inputData = [[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile];
    message = [[NSString alloc] initWithData:inputData encoding:NSUTF8StringEncoding];
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
        NSError *attachError = nil;
        UNNotificationAttachment *attachment =
          [UNNotificationAttachment attachmentWithIdentifier:@"contentImage"
                                                        URL:imageURL
                                                    options:nil
                                                      error:&attachError];
        if (attachment) {
          content.attachments = @[attachment];
        } else {
          TNError(@"[!] Could not attach '%@': %@",
                  options[@"contentImage"], attachError.localizedDescription);
        }
      }
    }

    // Metadata the click handler needs when the app is relaunched.
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    if (options[@"bundleID"]) userInfo[@"bundleID"] = options[@"bundleID"];
    if (groupID)              userInfo[@"groupID"]  = groupID;
    if (options[@"command"])  userInfo[@"command"]  = options[@"command"];
    if (options[@"open"])     userInfo[@"open"]     = options[@"open"];
    content.userInfo = userInfo;

    // Reusing an identifier is what makes a notification replace an earlier
    // one, so it must only happen when the caller actually asked for a group.
    // Sharing one identifier across all ungrouped notifications would make
    // every new notification silently overwrite the previous one.
    NSString *identifier = groupID ?: [[NSUUID UUID] UUIDString];

    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];

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
        exit(TNExitDeliveryFailed);
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
                        deliveredGroupID ?: @"",
                        content.title ?: @"",
                        content.subtitle ?: @"",
                        content.body ?: @"",
                        [notification.date description]]];
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

- (void)userActivatedNotification:(UNNotificationResponse *)response;
{
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
