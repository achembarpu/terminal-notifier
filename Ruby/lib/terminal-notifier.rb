# frozen_string_literal: true

require 'rbconfig'
require 'shellwords'

require 'terminal-notifier/version'

# Sends macOS User Notifications by shelling out to the bundled
# terminal-notifier application.
#
# See TerminalNotifier.notify, .remove and .list for the public API.
module TerminalNotifier
  # Minimum macOS version supported by the bundled binary. UNUserNotificationCenter,
  # which the tool is built on, is not available before this.
  MINIMUM_MACOS_VERSION = '10.14'

  # Exit code the binary uses when -timeout expires waiting for -action or
  # -reply. The notification was delivered correctly and the tool reported
  # @TIMEOUT, so this is an outcome to pass on rather than a failure.
  TIMEOUT_EXIT_CODE = 6

  # Path to the binary inside the vendored application bundle. Overridable so
  # that a Homebrew-installed or self-built copy can be used instead.
  BIN_PATH = ENV.fetch(
    'TERMINAL_NOTIFIER_BIN',
    File.expand_path(
      '../vendor/terminal-notifier/terminal-notifier.app/Contents/MacOS/terminal-notifier',
      __dir__
    )
  )

  class UnsupportedPlatformError < StandardError; end
  class BinaryNotFoundError < StandardError; end

  # Returns whether the current platform is macOS 10.14 or higher.
  def self.available?
    # Memoise with defined? rather than ||=, so that a false result is cached
    # too and we don't re-shell out on every single call.
    return @available if defined?(@available)

    @available = macos? && Gem::Version.new(version) >= Gem::Version.new(MINIMUM_MACOS_VERSION)
  end

  # The macOS product version, or nil when not running on macOS.
  def self.version
    return @version if defined?(@version)

    # Only shell out when we already know this is macOS. RbConfig reports the
    # Darwin kernel version, which doesn't map cleanly onto product versions,
    # so sw_vers is still needed for the number itself.
    @version = macos? ? `sw_vers -productVersion`.strip : nil
  end

  def self.macos?
    return @macos if defined?(@macos)

    @macos = !(RbConfig::CONFIG['host_os'] =~ /darwin|mac os/).nil?
  end

  # Builds the argument vector for the binary.
  #
  # A value of `true` becomes a bare flag and `false` omits the option entirely,
  # so switches like :reply and :ignoreDnD don't end up with a stray "true" as
  # their value (which -reply would show as its placeholder text).
  def self.command_for(options)
    arguments = options.flat_map do |key, value|
      case value
      when true then ["-#{key}"]
      when false, nil then []
      else ["-#{key}", escape_value(value.to_s)]
      end
    end
    [BIN_PATH, *arguments]
  end

  # Prepares a single option value for the binary.
  #
  # This is *not* shell escaping — IO.popen is handed an argv array, so no shell
  # is ever involved. It is the escaping the tool's own README documents as
  # ‘\[’: the binary reads its arguments through NSUserDefaults, which tries to
  # parse each value as a property list, so a value beginning with '[', '(',
  # '{', a quote, a space and so on comes back as nil and the notification is
  # never sent. Prefixing a backslash makes NSUserDefaults treat it as a plain
  # string, and the binary strips that backslash again (see
  # objectForKeyedSubscript: in AppDelegate.m).
  #
  # Shellwords.escape is used purely as a convenient test of "would this
  # character be taken as syntax", which is the same set that matters here.
  def self.escape_value(value)
    return value if value.empty?

    # A value starting with '-' would be read as the next flag; the binary
    # strips this leading space back off.
    prefix = value.start_with?('-') ? ' ' : ''
    "#{prefix}#{Shellwords.escape(value[0, 1])}#{value[1..]}"
  end

  # Runs the binary and returns its standard output.
  #
  # Raises UnsupportedPlatformError when not on a supported macOS, and
  # BinaryNotFoundError when the vendored binary is missing.
  def self.execute(verbose, options)
    ensure_usable!

    output = IO.popen(command_for(options), &:read)
    # Remember the status so callers aren't exposed to races on the global $?.
    Thread.current[:terminal_notifier_last_status] = $?
    $stdout.print output if verbose
    output
  end

  # Raises unless this platform and installation can actually run the binary.
  def self.ensure_usable!
    unless available?
      raise UnsupportedPlatformError,
            "terminal-notifier is only supported on macOS #{MINIMUM_MACOS_VERSION} or higher."
    end

    return if File.executable?(BIN_PATH)

    raise BinaryNotFoundError,
          "terminal-notifier binary not found at #{BIN_PATH}. " \
          'Set TERMINAL_NOTIFIER_BIN to point at it.'
  end

  # The exit status of the most recent execute call on this thread.
  def self.last_status
    Thread.current[:terminal_notifier_last_status]
  end

  def self.succeeded?
    status = last_status
    !status.nil? && status.success?
  end

  # True when the binary ran and reported an outcome, including a timeout.
  def self.reported?
    status = last_status
    return false if status.nil?

    status.success? || status.exitstatus == TIMEOUT_EXIT_CODE
  end

  # Cleans up the result of a notification, making it easier to work it
  #
  # The result of a notification is downcased, then groups of 1 or more
  # non-word characters are replaced with an underscore, before being
  # symbolised.
  #
  # If the reply option was given, then instead of going through the
  # above process, the result is returned with no changes as a string.
  #
  # If the always_string param is set to true, a the result is returned
  # with no changes as a string, like above.
  #
  # Examples are:
  #
  # notify_result('Test', {}) #=> :test
  # notify_result('No, sir', {}) #=> :no_sir
  # notify_result('@timeout', {}) #=> :_timeout
  # notify_result('@closeaction', {}) #=> :_closeaction
  # notify_result('I like pie', {reply: true}) #=> 'I like pie'
  # notify_result('I do not like pie', {'reply' => true}) #=> 'I do not like pie'
  # notify_result('@timeout', {'reply' => true}) #=> '@timeout'
  # notify_result('I may like pie', {}) #=> :i_may_like_pie
  def notify_result(result, options, always_string = false)
    # The binary terminates its response with a newline. Left on, a reply comes
    # back as "text\n" and an action title symbolises to :title_ because the
    # newline is a non-word character.
    result = result.to_s.chomp

    if options[:reply] || options['reply'] || always_string
      result
    else
      # NOTE: an empty result yields `true`, not a symbol, because the `||`
      # short-circuits. Odd, but it is the long-standing public contract.
      result.empty? || result.downcase.gsub(/\W+/, '_').to_sym
    end
  end
  module_function :notify_result

  # Sends a User Notification and returns whether or not it was a success.
  #
  # The available options are `:title`, `:subtitle`, `:group`, `:activate`,
  # `:open`, `:execute`, `:contentImage`, and `:sound`. For a description of
  # each option see:
  #
  #   https://github.com/julienXX/terminal-notifier/blob/master/README.markdown
  #
  # Examples are:
  #
  #   TerminalNotifier.notify('Hello World')
  #   TerminalNotifier.notify('Hello World', :title => 'Ruby')
  #   TerminalNotifier.notify('Hello World', :group => Process.pid)
  #   TerminalNotifier.notify('Hello World', :activate => 'com.apple.Safari')
  #   TerminalNotifier.notify('Hello World', :open => 'http://twitter.com/julienXX')
  #   TerminalNotifier.notify('Hello World', :execute => 'say "OMG"')
  #   TerminalNotifier.notify('Hello World', :sound => 'default')
  #
  # Raises UnsupportedPlatformError if not supported on the current platform.
  def notify(message, options = {}, verbose = false, always_string = false)
    result = TerminalNotifier.execute(verbose, options.merge(message: message))
    # A timeout counts as a reported outcome: without this it would come back as
    # a bare false, indistinguishable from the notification failing to send.
    TerminalNotifier.reported? && notify_result(result, options, always_string)
  end
  module_function :notify

  # Removes a notification that was previously sent with the specified
  # ‘group’ ID, if one exists.
  #
  # If no ‘group’ ID is given, all notifications are removed.
  # rubocop:disable Naming/PredicateMethod -- `remove` is the public API name
  def remove(group = 'ALL', verbose = false)
    TerminalNotifier.execute(verbose, remove: group)
    TerminalNotifier.succeeded?
  end
  # rubocop:enable Naming/PredicateMethod
  module_function :remove

  LIST_FIELDS = %i[group title subtitle message delivered_at].freeze

  # If a ‘group’ ID is given, and a notification for that group exists,
  # returns a hash with details about the notification.
  #
  # If no ‘group’ ID is given, an array of hashes describing all
  # notifications.
  #
  # If no information is available this will return `nil`.
  def list(group = 'ALL', verbose = false)
    output = TerminalNotifier.execute(verbose, list: group)
    return if output.nil? || output.strip.empty?

    require 'time'
    # Drop the header row.
    notifications = output.split("\n")[1..].to_a.map { |line| TerminalNotifier.parse_list_row(line) }

    group == 'ALL' ? notifications : notifications.first
  end
  module_function :list

  # Turns one tab-separated -list row into a hash.
  def self.parse_list_row(line)
    LIST_FIELDS.zip(line.split("\t")).each_with_object({}) do |(key, value), hash|
      hash[key] = key == :delivered_at ? parse_time(value) : presence(value)
    end
  end

  def self.parse_time(value)
    Time.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  # 3.0.0 emits an empty field for an absent value; earlier binaries emitted the
  # literal string "(null)".
  def self.presence(value)
    value unless value.nil? || value.empty? || value == '(null)'
  end
end
