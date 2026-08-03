# TerminalNotifier

A simple Ruby wrapper around the [`terminal-notifier`][HOMEPAGE] command-line
tool, which allows you to send User Notifications to the Notification Center on
macOS 10.14, or higher.

Requires Ruby 3.2 or newer.


## Installation

```
$ gem install terminal-notifier
```


## Usage

For full information on all the options, see the tool’s [README][README].

Examples are:

```ruby
TerminalNotifier.notify('Hello World')
TerminalNotifier.notify('Hello World', :title => 'Ruby', :subtitle => 'Programming Language')
TerminalNotifier.notify('Hello World', :activate => 'com.apple.Safari')
TerminalNotifier.notify('Hello World', :open => 'http://twitter.com/julienXX')
TerminalNotifier.notify('Hello World', :execute => 'say "OMG"')
TerminalNotifier.notify('Hello World', :group => Process.pid)
TerminalNotifier.notify('Hello World', :sound => 'default')
TerminalNotifier.notify('Hello World', :contentImage => './logo.png')

TerminalNotifier.remove(Process.pid)

TerminalNotifier.list(Process.pid)
TerminalNotifier.list
```

`:sender` and `:appIcon` were removed in 3.0.0. They are still accepted, but the
tool ignores them and warns on stderr — see the main [README][README].


## Asking a question

`:action` and `:reply` wait for the user and return what they chose. An option
whose value is `true` is passed as a bare flag.

```ruby
TerminalNotifier.notify('Deploy to production?', :action => 'Yes,No', :timeout => 30)
#=> :yes            (or :no, :_actionclicked, :_closed, :_timeout)

TerminalNotifier.notify("What's your name?", :reply => true, :timeout => 30)
#=> "Alice"         (a String, because :reply was given)
```

Action results come back symbolised by `notify_result`; a `:reply` result is
returned as the raw string.


## Return values

`notify` and `remove` return whether the command succeeded. `list` returns a
hash (or an array of hashes for the default `'ALL'` group) with the keys
`:group`, `:title`, `:subtitle`, `:message` and `:delivered_at`; absent fields
are `nil`. It returns `nil` when there is nothing to report.

Both raise `TerminalNotifier::UnsupportedPlatformError` when run on anything
other than a supported macOS, and `TerminalNotifier::BinaryNotFoundError` when
the bundled binary is missing.

Set `TERMINAL_NOTIFIER_BIN` to use a binary other than the bundled one.


## Development

```
$ cd Ruby
$ bundle install
$ bundle exec rspec
```

One example needs the compiled application bundle and is skipped without it.
Build and vendor it with `bundle exec rake update_build`, which requires Xcode.


## License

All the works are available under the MIT license. **Except** for
‘Terminal.icns’, which is a copy of Apple’s Terminal.app icon and as such is
copyright of Apple.

See [LICENSE][LICENSE] for details.

[HOMEPAGE]: https://github.com/julienXX/terminal-notifier
[README]: https://github.com/julienXX/terminal-notifier/blob/master/README.markdown
[LICENSE]: https://github.com/julienXX/terminal-notifier/blob/master/Ruby/LICENSE
