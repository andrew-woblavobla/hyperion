# frozen_string_literal: true

require 'logger'
require 'json'
require 'time'

module Hyperion
  # Structured logger.
  #
  # Usage:
  #   logger = Hyperion::Logger.new
  #   logger.info  { { message: 'listening', host: '127.0.0.1', port: 9292 } }
  #   logger.warn  { { message: 'parse error', error: e.message, error_class: e.class.name } }
  #   logger.error 'plain string also works for legacy callers'
  #
  # Level is set from:
  #   1. The `level:` constructor kwarg (highest precedence).
  #   2. ENV['HYPERION_LOG_LEVEL'] if set.
  #   3. Defaults to :info.
  #
  # Format is :text (key=value), :json (JSONL), or :auto (default — picks the
  # right one based on the runtime environment, see #pick_format below).
  #
  # Each log line is prefixed with timestamp + level + a 'hyperion' tag so
  # operators can grep multi-process worker output. When the resolved format
  # is :text and the underlying IO is a TTY, level names are ANSI-coloured
  # for readability.
  class Logger
    LEVELS = { debug: 0, info: 1, warn: 2, error: 3, fatal: 4 }.freeze

    LEVEL_COLORS = {
      debug: "\e[90m", # bright black / grey
      info: "\e[32m",  # green
      warn: "\e[33m",  # yellow
      error: "\e[31m",  # red
      fatal: "\e[35m"   # magenta
    }.freeze
    COLOR_RESET = "\e[0m"

    PRODUCTION_ENVS = %w[production staging].freeze

    attr_reader :level, :format

    # Levels at WARN or higher are routed to the error stream (stderr by
    # default). info / debug go to the regular stream (stdout by default).
    # 12-factor: app logs to stdout, errors to stderr.
    ERROR_LEVELS = %i[warn error fatal].freeze

    def initialize(out: $stdout, err: $stderr, io: nil, level: nil, format: nil)
      # `io:` is a back-compat alias for tests / single-IO use cases — it
      # routes both streams to the same target (e.g. a StringIO in specs).
      @out = io || out
      @err = io || err
      # Force line-immediate mode on real IO destinations. When stdout is
      # redirected (piped, journald, kubectl logs), Ruby/glibc default to
      # 4-KiB block buffering and small log lines never reach the consumer
      # until the buffer fills or the process exits. Operators expect to see
      # boot lines + access logs in real time. Match Puma's behaviour.
      @out.sync = true if @out.is_a?(::IO) && @out.respond_to?(:sync=)
      @err.sync = true if @err.is_a?(::IO) && @err.respond_to?(:sync=)
      @level = parse_level(level || ENV.fetch('HYPERION_LOG_LEVEL', 'info'))
      requested = format || ENV['HYPERION_LOG_FORMAT']
      @format = pick_format(requested)
      # Colorize when format is text AND the destination is a TTY. We only
      # check the regular stream here — colored text is for humans.
      @colorize = @format == :text && tty?(@out)
      @c_access_available = nil # lazy-computed on first access — see below.
      # Registry of every per-thread access buffer ever allocated through
      # this Logger instance. Walked by #flush_all on shutdown so SIGTERM
      # doesn't strand buffered lines in dying threads. The Mutex guards
      # registration on first allocation per thread (rare) and the shutdown
      # walk; the hot #access path stays lock-free.
      @access_buffers = []
      @access_buffers_mutex = Mutex.new
      # Per-instance thread-local key. A globally-shared key (e.g. a frozen
      # Symbol constant) lets a buffer created by an earlier Logger in this
      # thread be picked up by a later Logger — but the buffer is registered
      # against the *earlier* Logger's @access_buffers, so the new Logger's
      # #flush_all can't see it. Namespacing the key per-instance fixes that:
      # each Logger gets its own per-thread buffer, and the registry it
      # walks at shutdown matches the one #access wrote to. The Symbol is
      # allocated once at construction; the hot path just reads it.
      @buffer_key = :"__hyperion_access_buf_#{object_id}__"
    end

    # Whether Hyperion::CParser.build_access_line is available. Probed lazily
    # on first call (the C parser is required after Logger is required, so we
    # can't cache this at constant-define time — it would always be false).
    # Memoised per-instance to keep the hot path branchless.
    def c_access_available?
      return @c_access_available unless @c_access_available.nil?

      @c_access_available = defined?(::Hyperion::CParser) &&
                            ::Hyperion::CParser.respond_to?(:build_access_line)
    end

    LEVELS.each_key do |lvl|
      define_method(lvl) do |payload = nil, &block|
        next unless emit?(lvl)

        actual = block ? block.call : payload
        write(lvl, actual)
      end
    end

    # Pick the destination IO for a given level.
    # warn / error / fatal → @err (stderr default).
    # debug / info        → @out (stdout default).
    def io_for(lvl)
      ERROR_LEVELS.include?(lvl) ? @err : @out
    end

    def level=(lvl)
      @level = parse_level(lvl)
    end

    # Per-thread access-log buffer flush threshold. ~32 average-size lines
    # per write(2) call, well under PIPE_BUF (4096) so writes stay atomic.
    # Larger = fewer syscalls but higher latency-to-disk (up to ~32 reqs of
    # delay before the line shows up in the log file). 4 KiB is a good
    # balance: a 16-thread fleet at 24k r/s flushes ~750 buffers/sec total
    # vs ~24 000 syscalls/sec without buffering.
    ACCESS_FLUSH_BYTES = 4096

    # Hot-path access-log emitter — bypasses the generic format_text /
    # format_json kvs.join + hash#map allocations. The whole line is built
    # via a single interpolation, the timestamp is cached per-thread per
    # millisecond, and we batch lines into a per-thread buffer that flushes
    # when full (lock-free emit; POSIX write(2) is atomic for writes
    # <= PIPE_BUF / 4096 bytes).
    #
    # Returns silently on any IO error — logging must never crash the server.
    def access(method, path, query, status, duration_ms, remote_addr, http_version)
      return unless emit?(:info)

      ts = cached_timestamp
      # The C extension builds the line in a stack scratch buffer (~10× faster
      # than the Ruby interpolation path). It only fires when colorization is
      # off — a colored TTY line needs ANSI escapes around the level label,
      # which the C builder doesn't emit. Production deploys (non-TTY,
      # log-aggregator destinations) take the C path; local TTY runs keep the
      # colored Ruby fallback.
      line = if !@colorize && c_access_available?
               ::Hyperion::CParser.build_access_line(@format, ts, method, path,
                                                     query, status, duration_ms,
                                                     remote_addr, http_version)
             elsif @format == :json
               build_access_json(ts, method, path, query, status, duration_ms, remote_addr, http_version)
             else
               build_access_text(ts, method, path, query, status, duration_ms, remote_addr, http_version)
             end

      buf = Thread.current[@buffer_key] || allocate_access_buffer
      buf << line
      return if buf.bytesize < ACCESS_FLUSH_BYTES

      @out.write(buf)
      buf.clear
    rescue StandardError
      # Swallow logger failures — never let logging crash the server.
    end

    # Flush this thread's buffered access-log lines. Called by the connection
    # loop when a connection closes (so log lines from a closing keep-alive
    # session don't get stuck behind the buffer until the next connection).
    def flush_access_buffer
      buf = Thread.current[@buffer_key]
      return if buf.nil? || buf.empty?

      @out.write(buf)
      buf.clear
    rescue StandardError
      # Swallow logger failures — never let logging crash the server.
    end

    # Flush every per-thread access-log buffer ever allocated through this
    # Logger, then sync the underlying IOs.
    #
    # Why this exists: under SIGTERM, Master#shutdown_children logs the
    # 'master draining' / 'master exiting' lines and then exits. The 'info'
    # path doesn't go through the access buffer, but it does rely on glibc
    # stdio buffering being flushed before the process dies — and per-thread
    # access buffers (Thread.current[:__hyperion_access_buf__]) are *only*
    # flushed when the buffer reaches ACCESS_FLUSH_BYTES or when the owning
    # thread closes a connection. On a clean SIGTERM both can be missed and
    # the operator sees nothing in the captured log. This method walks every
    # registered per-thread buffer, writes any pending bytes, then calls
    # IO#flush on @out / @err so the kernel sees them before exec_exit.
    #
    # Safe to call from any thread. Idempotent. Never raises.
    def flush_all
      buffers = @access_buffers_mutex.synchronize { @access_buffers.dup }
      buffers.each do |buf|
        next if buf.empty?

        begin
          @out.write(buf)
          buf.clear
        rescue StandardError
          # Continue — one bad buffer must not block the rest.
        end
      end

      flush_io(@out)
      flush_io(@err) unless @err.equal?(@out)
    rescue StandardError
      # Swallow logger failures — never let logging crash the server.
    end

    private

    # First-touch path for a thread's access buffer. Allocates the String,
    # stores it in the thread-local for lock-free access on subsequent calls,
    # and registers it in @access_buffers so #flush_all can find it later.
    # Mutex is taken once per thread (not per request).
    def allocate_access_buffer
      buf = +''
      Thread.current[@buffer_key] = buf
      @access_buffers_mutex.synchronize { @access_buffers << buf }
      buf
    end

    def flush_io(io)
      io.flush if io.respond_to?(:flush)
    rescue StandardError
      # Some IO destinations raise on flush (closed pipes during SIGPIPE,
      # custom IO-likes that don't implement it cleanly). Logging must
      # never crash the server, especially during shutdown.
    end

    # Cached UTC iso8601(3) timestamp, refreshed at most once per millisecond
    # per thread. At 24k r/s with 16 threads we render ~1500 r/s/thread; only
    # ~1000 of those allocate a new String. The other 500 reuse the cached one.
    def cached_timestamp
      now_ms = Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond)
      cache = (Thread.current[:__hyperion_ts_cache__] ||= [-1, ''])
      return cache[1] if cache[0] == now_ms

      cache[0] = now_ms
      cache[1] = Time.now.utc.iso8601(3)
      cache[1]
    end

    # Resolve the effective format.
    # 1. If the operator passed an explicit value (kwarg or env), honour it.
    # 2. Else, if the app is running in a production-ish env (RAILS_ENV /
    #    RACK_ENV / HYPERION_ENV), default to JSON — log aggregators love it.
    # 3. Else, if stderr is a TTY, default to colored text — humans prefer it.
    # 4. Else (piped/redirected output, no env hint), default to JSON so
    #    captured logs are parseable by tooling.
    def pick_format(requested)
      if requested && !requested.to_s.empty? && requested.to_s != 'auto'
        sym = requested.to_s.to_sym
        return sym if %i[text json].include?(sym)
      end

      env_name = ENV['HYPERION_ENV'] || ENV['RAILS_ENV'] || ENV['RACK_ENV']
      return :json if env_name && PRODUCTION_ENVS.include?(env_name)
      return :text if tty?(@out)

      :json
    end

    def tty?(io)
      io.respond_to?(:tty?) && io.tty?
    rescue StandardError
      false
    end

    def emit?(lvl)
      LEVELS.fetch(lvl) >= LEVELS.fetch(@level)
    end

    def write(lvl, payload)
      hash = case payload
             when Hash then payload
             when nil  then { message: '' }
             else { message: payload.to_s }
             end

      line = case @format
             when :json then format_json(lvl, hash)
             else format_text(lvl, hash)
             end

      # No mutex: POSIX write(2) is atomic for writes <= PIPE_BUF (4096 bytes)
      # on regular FDs, pipes, and sockets. A single log line is ~200 bytes.
      # Ruby's IO#write is a thin wrapper; concurrent threads writing short
      # lines don't interleave bytes within a line. Skipping flush, too:
      # stdout/stderr are line-buffered or unbuffered respectively when
      # attached to a terminal, and removing the syscall saves ~30% of the
      # logger overhead.
      io_for(lvl).write(line)
    rescue StandardError
      # Swallow logger failures — never let logging crash the server.
    end

    def format_text(lvl, hash)
      ts = cached_timestamp
      level_label = lvl.to_s.upcase.ljust(5)
      level_label = "#{LEVEL_COLORS[lvl]}#{level_label}#{COLOR_RESET}" if @colorize
      kvs = hash.map { |k, v| "#{k}=#{format_value(v)}" }.join(' ')
      "#{ts} #{level_label} [hyperion] #{kvs}\n"
    end

    def format_json(lvl, hash)
      hash = { ts: cached_timestamp, level: lvl.to_s, source: 'hyperion' }.merge(hash)
      "#{JSON.generate(hash)}\n"
    end

    # Hand-rolled text access-log line — single interpolation, no Hash#map,
    # no Array#join. Matches the structured-hash format users got in rc9
    # (key=value pairs starting with `message=request`) so existing log
    # parsers keep working.
    def build_access_text(ts, method, path, query, status, duration_ms, remote_addr, http_version)
      level_label = @colorize ? "#{LEVEL_COLORS[:info]}INFO #{COLOR_RESET}" : 'INFO '
      addr = remote_addr || 'nil'
      query_part = query.nil? || query.empty? ? '' : " query=#{quote_if_needed(query)}"
      "#{ts} #{level_label} [hyperion] message=request method=#{method} path=#{path}#{query_part} " \
        "status=#{status} duration_ms=#{duration_ms} remote_addr=#{addr} http_version=#{http_version}\n"
    end

    # Hand-rolled JSON access-log line — single interpolation, skips
    # JSON.generate's Hash walk. The values we write are all server-controlled
    # (method/path/status/etc) and well-formed; we only need to escape path
    # and query. Status/duration_ms are numeric, not quoted.
    def build_access_json(ts, method, path, query, status, duration_ms, remote_addr, http_version)
      query_field = query.nil? || query.empty? ? '' : %(,"query":#{json_str(query)})
      addr_field = remote_addr.nil? ? 'null' : json_str(remote_addr)
      %({"ts":"#{ts}","level":"info","source":"hyperion","message":"request",) +
        %("method":"#{method}","path":#{json_str(path)}#{query_field},) +
        %("status":#{status},"duration_ms":#{duration_ms},"remote_addr":#{addr_field},) +
        %("http_version":"#{http_version}"}\n)
    end

    # Cheap JSON string serializer — defers to JSON.generate for any value
    # that needs escaping (control chars, quotes, backslashes). Hot path
    # (paths like /, /api/v1/games) skips JSON.generate entirely.
    def json_str(value)
      s = value.to_s
      return %("#{s}") if s.match?(%r{\A[A-Za-z0-9._\-/?=&%:+,@!~*';()\[\] ]*\z})

      JSON.generate(s)
    end

    # Mirror format_value's quoting rule for access-log query strings.
    def quote_if_needed(value)
      s = value.to_s
      s.match?(/[\s"=]/) ? s.inspect : s
    end

    def format_value(v)
      case v
      when nil then 'nil'
      when String
        v.match?(/[\s"=]/) ? v.inspect : v
      else
        v.to_s
      end
    end

    def parse_level(lvl)
      sym = lvl.to_s.downcase.to_sym
      LEVELS.key?(sym) ? sym : :info
    end
  end
end
