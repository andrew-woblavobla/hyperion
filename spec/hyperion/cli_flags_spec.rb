# frozen_string_literal: true

require 'tempfile'
require 'hyperion/cli'

# Smoke tests for the 1.5.0 CLI flag coverage additions. These exercise the
# OptionParser wiring directly (no server boot) and assert the flag values
# land on Config via the existing merge_cli! precedence chain. We deliberately
# avoid spawning the binary — those E2E checks live in cli_config_spec.rb.
RSpec.describe 'Hyperion::CLI option parsing' do
  def parse(argv)
    # parse_argv! mutates argv in place (removes parsed flags, leaves
    # positional args). Dup so the spec's expected-argv is untouched.
    Hyperion::CLI.parse_argv!(argv.dup)
  end

  it 'parses --max-body-bytes as Integer' do
    cli_opts, = parse(%w[--max-body-bytes 1048576])
    expect(cli_opts[:max_body_bytes]).to eq(1_048_576)
  end

  it 'parses --max-header-bytes as Integer' do
    cli_opts, = parse(%w[--max-header-bytes 32768])
    expect(cli_opts[:max_header_bytes]).to eq(32_768)
  end

  it 'parses --max-pending as Integer' do
    cli_opts, = parse(%w[--max-pending 256])
    expect(cli_opts[:max_pending]).to eq(256)
  end

  it 'parses --max-request-read-seconds as Float' do
    cli_opts, = parse(%w[--max-request-read-seconds 12.5])
    expect(cli_opts[:max_request_read_seconds]).to eq(12.5)
  end

  it 'parses --admin-token as String' do
    cli_opts, = parse(['--admin-token', 's3cr3t-token'])
    expect(cli_opts[:admin_token]).to eq('s3cr3t-token')
  end

  it 'parses --worker-max-rss-mb as Integer' do
    cli_opts, = parse(%w[--worker-max-rss-mb 1024])
    expect(cli_opts[:worker_max_rss_mb]).to eq(1024)
  end

  it 'parses --idle-keepalive as Float' do
    cli_opts, = parse(%w[--idle-keepalive 2.5])
    expect(cli_opts[:idle_keepalive]).to eq(2.5)
  end

  it 'parses --graceful-timeout as Integer' do
    cli_opts, = parse(%w[--graceful-timeout 60])
    expect(cli_opts[:graceful_timeout]).to eq(60)
  end

  it 'lands all new flags on Config via merge_cli!' do
    cli_opts, = parse(%w[
                        --max-body-bytes 2097152
                        --max-header-bytes 16384
                        --max-pending 128
                        --max-request-read-seconds 45.0
                        --admin-token tok
                        --worker-max-rss-mb 768
                        --idle-keepalive 7.5
                        --graceful-timeout 90
                      ])

    config = Hyperion::Config.new
    config.merge_cli!(cli_opts)

    expect(config.max_body_bytes).to eq(2_097_152)
    expect(config.max_header_bytes).to eq(16_384)
    expect(config.max_pending).to eq(128)
    expect(config.max_request_read_seconds).to eq(45.0)
    expect(config.admin.token).to eq('tok')
    expect(config.worker_health.max_rss_mb).to eq(768)
    expect(config.idle_keepalive).to eq(7.5)
    expect(config.graceful_timeout).to eq(90)
  end

  it 'preserves CLI > config-file precedence (CLI wins)' do
    config = Hyperion::Config.new
    config.max_body_bytes  = 100 # simulate value from config file
    config.admin.token     = 'from-file'
    config.idle_keepalive  = 99.0

    cli_opts, = parse(['--max-body-bytes', '200', '--admin-token', 'from-cli'])
    config.merge_cli!(cli_opts)

    expect(config.max_body_bytes).to eq(200)        # overridden
    expect(config.admin.token).to eq('from-cli')    # overridden
    expect(config.idle_keepalive).to eq(99.0)       # untouched (no CLI flag)
  end

  describe '--admin-token-file' do
    it 'reads the token from a file with secure permissions' do
      file = Tempfile.new('hyperion-token')
      file.write("file-token\n")
      file.close
      File.chmod(0o600, file.path)

      cli_opts, = parse(['--admin-token-file', file.path])
      expect(cli_opts[:admin_token]).to eq('file-token')
    ensure
      file&.unlink
    end

    it 'aborts when the file is world-readable' do
      file = Tempfile.new('hyperion-token-bad')
      file.write('exposed')
      file.close
      File.chmod(0o644, file.path)

      expect { parse(['--admin-token-file', file.path]) }
        .to raise_error(SystemExit)
    ensure
      file&.unlink
    end

    it 'aborts when the file does not exist' do
      expect { parse(['--admin-token-file', '/tmp/hyperion-token-does-not-exist-9999']) }
        .to raise_error(SystemExit)
    end

    it 'aborts when the file is empty' do
      file = Tempfile.new('hyperion-token-empty')
      file.close
      File.chmod(0o600, file.path)

      expect { parse(['--admin-token-file', file.path]) }
        .to raise_error(SystemExit)
    ensure
      file&.unlink
    end
  end
end
