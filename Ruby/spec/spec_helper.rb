# frozen_string_literal: true

require 'terminal-notifier'
require 'terminal-notifier/cli'
require 'stringio'
require 'time'

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed

  config.expect_with :rspec do |expectations|
    expectations.syntax = :expect
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  # The vendored binary is a build artifact; skip the tests that need a real
  # one rather than failing when it hasn't been built.
  config.before(:example, :binary) do
    unless File.executable?(TerminalNotifier::BIN_PATH)
      skip "binary not built at #{TerminalNotifier::BIN_PATH} (run `rake update_build`)"
    end
  end
end
