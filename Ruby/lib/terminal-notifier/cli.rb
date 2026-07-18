# frozen_string_literal: true

require 'terminal-notifier'

module TerminalNotifier
  # The bin wrapper's logic, extracted so that it can be tested without
  # spawning a process.
  module CLI
    # Folds piped stdin into a -message option, matching the behaviour of the
    # binary itself when data is piped to it directly.
    def self.argv_for(argv, stdin)
      return argv if argv.include?('-message') || stdin.tty?

      argv + ['-message', stdin.read.chomp]
    end

    def self.run(argv = ARGV, stdin = $stdin)
      exec TerminalNotifier::BIN_PATH, *argv_for(argv, stdin)
    end
  end
end
