# frozen_string_literal: true

require File.expand_path('lib/terminal-notifier/version', __dir__)

Gem::Specification.new do |gem|
  gem.name        = 'terminal-notifier'
  gem.version     = TerminalNotifier::VERSION
  gem.summary     = 'Send User Notifications on macOS 10.14 or higher.'
  gem.description = <<~DESC
    terminal-notifier is a command-line tool to send macOS User Notifications.
    This gem wraps the tool and ships the application bundle it needs, so that
    notifications can be posted from Ruby without any extra installation.
  DESC
  gem.authors  = ['Eloy Duran', 'Julien Blanchard']
  gem.email    = ['eloy.de.enige@gmail.com', 'julien@sideburns.eu']
  gem.homepage = 'https://github.com/julienXX/terminal-notifier'
  gem.license  = 'MIT'

  gem.required_ruby_version = '>= 3.2'

  gem.metadata = {
    'source_code_uri' => gem.homepage,
    'bug_tracker_uri' => "#{gem.homepage}/issues",
    'changelog_uri' => "#{gem.homepage}/releases",
    'rubygems_mfa_required' => 'true'
  }

  gem.executables   = ['terminal-notifier']
  gem.require_paths = ['lib']

  # The vendored application bundle is deliberately gitignored (it is a build
  # artifact produced by `rake update_build`), so the file list cannot come
  # from `git ls-files`.
  gem.files = [
    'bin/terminal-notifier',
    'lib/terminal-notifier.rb',
    'lib/terminal-notifier/version.rb',
    'lib/terminal-notifier/cli.rb',
    'README.markdown',
    'LICENSE'
  ] + Dir.glob('vendor/terminal-notifier/**/*', base: __dir__).select do |path|
    File.file?(File.join(__dir__, path))
  end

  gem.extra_rdoc_files = ['README.markdown']
end
