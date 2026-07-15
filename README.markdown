# terminal-notifier

[![GitHub release](https://img.shields.io/github/release/julienXX/terminal-notifier.svg)](https://github.com/julienXX/terminal-notifier/releases)

terminal-notifier is a command-line tool to send macOS User Notifications,
which are available on macOS 10.14 and higher.


## News

[alerter](https://github.com/vjeantet/alerter) features were merged in terminal-notifier 1.7. This led to some issues and even more issues in the 1.8 release. We decided with [Valère Jeantet](https://github.com/vjeantet) to rollback this merge.

From now on terminal-notifier won't have the sticky notification feature nor the actions buttons. If you need them please use [alerter](https://github.com/vjeantet/alerter). I also want to follow [semver](http://semver.org) hence this latest version starts at 2.0.0.

Sticking to two smaller specialized tools will hopefully make them easier to maintain and less error prone.


## Caveats

* It is packaged as an application bundle rather than a plain executable. A
  notification is attributed to a bundle identity, so a ‘Foundation tool’ has
  nothing to post as. This was true of `NSUserNotification` and remains true of
  `UNUserNotificationCenter`. [radar://11956694](radar://11956694)

* As of 3.0.0 terminal-notifier uses only public API. Versions 1.6.0 through
  2.0.0 relied on a private method override and on swizzling the bundle
  identifier, neither of which is permitted by the App Store Guidelines and
  both of which stopped working on modern macOS.

* If you're using macOS < 10.14 you should use terminal-notifier 2.0.0. If
  you're using macOS < 10.10, use 1.6.3.

* The notification icon always comes from the application bundle. macOS
  provides no API to override it per notification, so if you want a custom
  icon you need your own copy of the bundle: duplicate `terminal-notifier.app`,
  replace `Contents/Resources/Terminal.icns`, adjust `CFBundleIdentifier` in
  `Contents/Info.plist`, and re-sign it with `codesign --force --sign - YourApp.app`.

* If you're looking for sticky notifications or more actions on a notification please use [alerter](https://github.com/vjeantet/alerter)

## Download

Prebuilt binaries are available from the
[releases section](https://github.com/julienXX/terminal-notifier/releases).

Or if you want to use this from
[Ruby](https://github.com/julienXX/terminal-notifier/tree/master/Ruby), you can
install it through RubyGems:

```
$ [sudo] gem install terminal-notifier
```

You can also install it via [Homebrew](https://github.com/mxcl/homebrew):
```
$ brew install terminal-notifier
```

## Usage

```
$ ./terminal-notifier.app/Contents/MacOS/terminal-notifier -[message|group|list] [VALUE|ID|ID] [options]
```

In order to use terminal-notifier, you have to call the binary _inside_ the
application bundle.

The Ruby gem, which wraps this tool, _does_ have a bin wrapper. If installed
you can simply do:

```
$ terminal-notifier -[message|group|list] [VALUE|ID|ID] [options]
```

This will obviously be a bit slower than using the tool without the wrapper.

If you'd like notifications to stay on the screen until dismissed, go to System
Settings -> Notifications -> terminal-notifier and change the style from Banners
to Alerts. You cannot do this on a per-notification basis.

If notifications do not appear at all, check that terminal-notifier is allowed to
send them in System Settings -> Notifications, and that a Focus mode is not
suppressing them. To make macOS ask for permission again:

```
$ tccutil reset UserNotification fr.julienxx.oss.terminal-notifier
```


### Example Uses

Display piped data with a sound:
```
$ echo 'Piped Message Data!' | terminal-notifier -sound default
```

![Example 1](assets/Example_1.png)

Attach an image to the notification:
```
$ terminal-notifier -title ProjectX -subtitle "new tag detected" -message "Finished" -contentImage ./logo.png
```

![Example 3](assets/Example_3.png)

To change the *icon* rather than attach an image, see the Caveats section — it
requires your own copy of the application bundle.

Open an URL when the notification is clicked:
```
$ terminal-notifier -title '💰' -message 'Check your Apple stock!' -open 'http://finance.yahoo.com/q?s=AAPL'
```

![Example 4](assets/Example_4.png)

Open an app when the notification is clicked:
```
$ terminal-notifier -group 'address-book-sync' -title 'Address Book Sync' -subtitle 'Finished' -message 'Imported 42 contacts.' -activate 'com.apple.AddressBook'
```

![Example 5](assets/Example_5.png)


### Options

At a minimum, you must specify either the `-message` , the `-remove`, or the
`-list` option.

-------------------------------------------------------------------------------

`-message VALUE`  **[required]**

The message body of the notification.

If you pipe data into terminal-notifier, you can omit this option,
and the piped data will become the message body instead.

-------------------------------------------------------------------------------

`-title VALUE`

The title of the notification. This defaults to ‘Terminal’.

-------------------------------------------------------------------------------

`-subtitle VALUE`

The subtitle of the notification.

-------------------------------------------------------------------------------

`-sound NAME`

Play the `NAME` sound when the notification appears.
Sound names are listed in `/System/Library/Sounds`.

Use the special `NAME` “default” for the default notification sound.

-------------------------------------------------------------------------------

`-group ID`

Specifies the notification’s ‘group’. For any ‘group’, only _one_
notification will ever be shown, replacing previously posted notifications.

A notification can be explicitly removed with the `-remove` option (see
below).

Example group IDs:

* The sender’s name (to scope the notifications by tool).
* The sender’s process ID (to scope the notifications by a unique process).
* The current working directory (to scope notifications by project).

-------------------------------------------------------------------------------

`-remove ID`  **[required]**

Remove a previous notification from the `ID` ‘group’, if one exists.

Use the special `ID` “ALL” to remove all messages.

-------------------------------------------------------------------------------

`-list ID` **[required]**

Lists details about the specified ‘group’ `ID`.

Use the special `ID` “ALL” to list details about all currently active messages.

The output of this command is tab-separated, which makes it easy to parse.

-------------------------------------------------------------------------------

`-activate ID`

Activate the application specified by `ID` when the user clicks the
notification.

You can find the bundle identifier (`CFBundleIdentifier`) of an application in its `Info.plist` file
_inside_ the application bundle.

Examples application IDs are:

* `com.apple.Terminal` to activate Terminal.app
* `com.apple.Safari` to activate Safari.app

-------------------------------------------------------------------------------

`-sender ID`

**Removed in 3.0.0.** Accepted but ignored, with a warning.

This worked by swizzling terminal-notifier's own bundle identifier at runtime.
The UserNotifications framework reads the real, signed bundle identity, so
there is no way to reimplement it. Use `-activate` to bring an application
forward when the notification is clicked.

-------------------------------------------------------------------------------

`-appIcon PATH`

**Removed in 3.0.0.** Accepted but ignored, with a warning.

`UNNotificationContent` has no icon property at all — the icon always comes from
the application bundle. See the Caveats section for the custom-bundle
workaround.

-------------------------------------------------------------------------------

`-contentImage PATH`

Specify an image `PATH` to attach inside of the notification.

Local file paths only. Earlier versions accepted remote URLs; the attachment API
does not, so download the image first if you need this.

-------------------------------------------------------------------------------

`-open URL`

Open `URL` when the user clicks the notification. This can be a web or file URL,
or any custom URL scheme.

-------------------------------------------------------------------------------

`-execute COMMAND`

Run the shell command `COMMAND` when the user clicks the notification.

-------------------------------------------------------------------------------

`-ignoreDnD`

Request delivery even when Do Not Disturb is enabled. **Best effort only — in
most builds this does nothing.**

This previously worked by setting a private ivar. The public equivalent is a
time-sensitive interruption level, which requires an Apple-granted entitlement
that the released binary does not carry. The flag is still accepted so existing
scripts keep working.

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Usage error — no `-message`, `-remove` or `-list` given |
| 2 | Invalid argument, e.g. a malformed `-open` URL |
| 3 | Notifications are not authorized for this application |
| 4 | Timed out — usually no GUI session (over SSH, or launchd as root) |
| 5 | The notification service refused the request |

## License

All the works are available under the MIT license. **Except** for
‘Terminal.icns’, which is a copy of Apple’s Terminal.app icon and as such is
copyright of Apple.

Copyright (C) 2012-2017 Eloy Durán <eloy.de.enige@gmail.com>, Julien Blanchard
<julien@sideburns.eu>

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
