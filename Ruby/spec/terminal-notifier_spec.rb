# frozen_string_literal: true

RSpec.describe TerminalNotifier do
  # available? / version / macos? memoise, so reset between examples.
  before do
    %i[@available @version @macos].each do |ivar|
      described_class.remove_instance_variable(ivar) if described_class.instance_variable_defined?(ivar)
    end
    Thread.current[:terminal_notifier_last_status] = nil
  end

  def stub_available
    allow(described_class).to receive(:available?).and_return(true)
    allow(File).to receive(:executable?).with(TerminalNotifier::BIN_PATH).and_return(true)
  end

  describe '.command_for' do
    it 'backslash-escapes a first character NSUserDefaults would misparse' do
      # Not shell escaping (IO.popen gets an argv array). Without the backslash
      # the binary's NSUserDefaults parse yields nil and nothing is sent; the
      # binary strips the backslash again. This is the README's ‘\[’ escaping.
      expect(described_class.command_for(message: '[ZOMG] "OH YEAH"'))
        .to eq [TerminalNotifier::BIN_PATH, '-message', '\\[ZOMG] "OH YEAH"']
    end

    it 'leaves an ordinary first character alone' do
      expect(described_class.command_for(message: 'plain message'))
        .to eq [TerminalNotifier::BIN_PATH, '-message', 'plain message']
    end

    it 'prefixes a space to values starting with a dash' do
      expect(described_class.command_for(message: '-kittens', title: '-rule'))
        .to eq [TerminalNotifier::BIN_PATH, '-message', ' -kittens', '-title', ' -rule']
    end

    it 'passes an empty value as an empty argument' do
      expect(described_class.command_for('help' => '')).to eq [TerminalNotifier::BIN_PATH, '-help', '']
    end

    it 'escapes a leading quote too' do
      expect(described_class.command_for(message: '"quoted"'))
        .to eq [TerminalNotifier::BIN_PATH, '-message', '\\"quoted"']
    end

    it 'stringifies non-string values' do
      expect(described_class.command_for(group: 1234))
        .to eq [TerminalNotifier::BIN_PATH, '-group', '1234']
    end

    it 'emits a bare flag for a true value' do
      expect(described_class.command_for(reply: true))
        .to eq [TerminalNotifier::BIN_PATH, '-reply']
    end

    it 'omits an option whose value is false or nil' do
      expect(described_class.command_for(reply: false, ignoreDnD: nil))
        .to eq [TerminalNotifier::BIN_PATH]
    end

    it 'passes -in through untouched' do
      expect(described_class.command_for(message: 'later', in: '5m'))
        .to eq [TerminalNotifier::BIN_PATH, '-message', 'later', '-in', '5m']
    end

    it 'passes an -at value containing a space as one argument' do
      # IO.popen gets an argv array, so the space needs no quoting; it must not
      # be split into two arguments or the binary sees a date with no time.
      expect(described_class.command_for(message: 'later', at: '2026-09-01 02:00'))
        .to eq [TerminalNotifier::BIN_PATH, '-message', 'later', '-at', '2026-09-01 02:00']
    end

    it 'stringifies a numeric -in' do
      expect(described_class.command_for(in: 90))
        .to eq [TerminalNotifier::BIN_PATH, '-in', '90']
    end
  end

  describe '.execute' do
    before { stub_available }

    it 'invokes the binary with an argument vector, so no shell is involved' do
      expect(IO).to receive(:popen)
        .with([TerminalNotifier::BIN_PATH, '-message', 'ZOMG'])
        .and_yield(StringIO.new('output'))
      described_class.execute(false, message: 'ZOMG')
    end

    it 'returns the output of the command' do
      allow(IO).to receive(:popen).and_yield(StringIO.new('output'))
      expect(described_class.execute(false, message: 'ZOMG')).to eq 'output'
    end

    it 'prints the output when verbose' do
      allow(IO).to receive(:popen).and_yield(StringIO.new('output'))
      expect { described_class.execute(true, message: 'ZOMG') }.to output('output').to_stdout
    end

    it 'stays quiet when not verbose' do
      allow(IO).to receive(:popen).and_yield(StringIO.new('output'))
      expect { described_class.execute(false, message: 'ZOMG') }.not_to output.to_stdout
    end

    it 'raises UnsupportedPlatformError when the platform is unsupported' do
      allow(described_class).to receive(:available?).and_return(false)
      expect { described_class.execute(false, message: 'ZOMG') }
        .to raise_error(TerminalNotifier::UnsupportedPlatformError, /10\.14/)
    end

    it 'raises BinaryNotFoundError when the vendored binary is missing' do
      allow(File).to receive(:executable?).with(TerminalNotifier::BIN_PATH).and_return(false)
      expect { described_class.execute(false, message: 'ZOMG') }
        .to raise_error(TerminalNotifier::BinaryNotFoundError, /TERMINAL_NOTIFIER_BIN/)
    end
  end

  describe '.available?' do
    it 'is false off macOS' do
      allow(RbConfig::CONFIG).to receive(:[]).with('host_os').and_return('linux-gnu')
      expect(described_class).not_to be_available
    end

    it 'is true on exactly the minimum supported version' do
      allow(described_class).to receive(:macos?).and_return(true)
      allow(described_class).to receive(:version).and_return('10.14')
      expect(described_class).to be_available
    end

    it 'is false below the minimum supported version' do
      allow(described_class).to receive(:macos?).and_return(true)
      allow(described_class).to receive(:version).and_return('10.13')
      expect(described_class).not_to be_available
    end

    it 'is true on a current macOS' do
      allow(described_class).to receive(:macos?).and_return(true)
      allow(described_class).to receive(:version).and_return('26.6.2')
      expect(described_class).to be_available
    end

    it 'memoises a false result instead of recomputing it' do
      allow(described_class).to receive(:macos?).and_return(false)
      described_class.available?
      expect(described_class).not_to receive(:macos?)
      described_class.available?
    end
  end

  describe '.version' do
    it 'is nil off macOS' do
      allow(described_class).to receive(:macos?).and_return(false)
      expect(described_class.version).to be_nil
    end
  end

  describe '.notify' do
    it 'delegates to execute with the message folded into the options' do
      # Braces matter here: notify passes options.merge(...), i.e. a positional
      # Hash, which Ruby 3 keeps distinct from keyword arguments.
      expect(described_class).to receive(:execute)
        .with(false, { message: 'ZOMG', group: 'important stuff' })
      described_class.notify('ZOMG', group: 'important stuff')
    end

    it 'reports a timeout as a result rather than a failure' do
      # The binary exits 6 on -timeout, but it delivered the notification and
      # said what happened, so the caller should see :_timeout not false.
      allow(described_class).to receive(:execute).and_return("@TIMEOUT\n")
      allow(described_class).to receive(:last_status)
        .and_return(instance_double(Process::Status, success?: false, exitstatus: 6))
      expect(described_class.notify('Deploy?', action: 'Yes,No')).to eq :_timeout
    end

    it 'returns false when the command failed' do
      allow(described_class).to receive(:execute).and_return('')
      allow(described_class).to receive(:succeeded?).and_return(false)
      expect(described_class.notify('ZOMG')).to be false
    end
  end

  describe '.remove' do
    it 'removes the given group' do
      expect(described_class).to receive(:execute).with(false, remove: 'important stuff')
      described_class.remove('important stuff')
    end

    it 'removes all notifications by default' do
      expect(described_class).to receive(:execute).with(false, remove: 'ALL')
      described_class.remove
    end
  end

  describe '.notify_result' do
    it 'symbolises the result' do
      expect(described_class.notify_result('Test', {})).to eq :test
      expect(described_class.notify_result('No, sir', {})).to eq :no_sir
      expect(described_class.notify_result('@timeout', {})).to eq :_timeout
    end

    it 'returns the raw string when :reply was given' do
      expect(described_class.notify_result('I like pie', reply: true)).to eq 'I like pie'
      expect(described_class.notify_result('I like pie', 'reply' => true)).to eq 'I like pie'
    end

    it 'returns the raw string when always_string is set' do
      expect(described_class.notify_result('@timeout', {}, true)).to eq '@timeout'
    end

    it 'strips the trailing newline the binary emits' do
      expect(described_class.notify_result("Ship\n", {})).to eq :ship
      expect(described_class.notify_result("blue\n", reply: true)).to eq 'blue'
    end

    it 'returns true for an empty result' do
      # Odd, but long-standing public behaviour: the `||` short-circuits before
      # a symbol is ever produced.
      expect(described_class.notify_result('', {})).to be true
    end
  end

  describe '.list' do
    it 'returns nil when nothing was found' do
      allow(described_class).to receive(:execute).with(false, list: 'important stuff').and_return('')
      expect(described_class.list('important stuff')).to be_nil
    end

    it 'returns nil when the output is only whitespace' do
      allow(described_class).to receive(:execute).and_return("\n")
      expect(described_class.list('whatever')).to be_nil
    end

    it 'parses a single group, treating an empty field as nil' do
      allow(described_class).to receive(:execute).with(false, list: 'important stuff').and_return(
        "GroupID\tTitle\tSubtitle\tMessage\tDelivered At\n" \
        "important stuff\tTerminal\t\tExecute: rake spec\t2012-08-06 19:45:30 +0000"
      )
      expect(described_class.list('important stuff')).to eq(
        group: 'important stuff', title: 'Terminal', subtitle: nil,
        message: 'Execute: rake spec',
        delivered_at: Time.parse('2012-08-06 19:45:30 +0000')
      )
    end

    it 'still understands the legacy "(null)" placeholder' do
      # Binaries before 3.0.0 printed "(null)" rather than an empty field.
      allow(described_class).to receive(:execute).and_return(
        "GroupID\tTitle\tSubtitle\tMessage\tDelivered At\n" \
        "important stuff\tTerminal\t(null)\tExecute: rake spec\t2012-08-06 19:45:30 +0000"
      )
      expect(described_class.list('important stuff')[:subtitle]).to be_nil
    end

    it 'returns every notification by default' do
      allow(described_class).to receive(:execute).with(false, list: 'ALL').and_return(
        "GroupID\tTitle\tSubtitle\tMessage\tDelivered At\n" \
        "important stuff\tTerminal\t\tExecute: rake spec\t2012-08-06 19:45:30 +0000\n" \
        "\t\tSubtle\tBe subtle!\t2012-08-07 19:45:30 +0000"
      )
      expect(described_class.list).to eq [
        { group: 'important stuff', title: 'Terminal', subtitle: nil,
          message: 'Execute: rake spec',
          delivered_at: Time.parse('2012-08-06 19:45:30 +0000') },
        { group: nil, title: nil, subtitle: 'Subtle',
          message: 'Be subtle!',
          delivered_at: Time.parse('2012-08-07 19:45:30 +0000') }
      ]
    end

    it 'does not blow up on an unparseable delivery date' do
      allow(described_class).to receive(:execute).and_return(
        "GroupID\tTitle\tSubtitle\tMessage\tDelivered At\n" \
        "g\tt\ts\tm\tnot a date"
      )
      expect(described_class.list('g')[:delivered_at]).to be_nil
    end

    it 'returns every row for PENDING, not just the first' do
      allow(described_class).to receive(:execute).with(false, list: 'PENDING').and_return(
        "GroupID\tTitle\tSubtitle\tMessage\tScheduled For\n" \
        "backup\tTerminal\t\tStarting\t2026-09-01 02:00:00 +0000\n" \
        "standup\tTerminal\t\tStandup\t2026-09-02 09:15:00 +0000"
      )
      expect(described_class.list('PENDING').map { |n| n[:group] }).to eq %w[backup standup]
    end

    it 'parses the scheduled time of a PENDING row into :delivered_at' do
      allow(described_class).to receive(:execute).with(false, list: 'PENDING').and_return(
        "GroupID\tTitle\tSubtitle\tMessage\tScheduled For\n" \
        "backup\tTerminal\t\tStarting\t2026-09-01 02:00:00 +0000"
      )
      expect(described_class.list('PENDING').first[:delivered_at])
        .to eq Time.parse('2026-09-01 02:00:00 +0000')
    end
  end

  describe TerminalNotifier::CLI do
    describe '.argv_for' do
      it 'appends piped stdin as the message' do
        expect(described_class.argv_for([], StringIO.new("piped\n")))
          .to eq ['-message', 'piped']
      end

      it 'leaves an explicit -message alone' do
        expect(described_class.argv_for(['-message', 'given'], StringIO.new('piped')))
          .to eq ['-message', 'given']
      end

      it 'preserves the other arguments' do
        expect(described_class.argv_for(['-title', 'T'], StringIO.new('piped')))
          .to eq ['-title', 'T', '-message', 'piped']
      end
    end
  end

  describe 'the real binary', :binary do
    it 'prints its help banner' do
      expect(described_class.execute(false, 'help' => '')).to include('command-line tool')
    end
  end
end
