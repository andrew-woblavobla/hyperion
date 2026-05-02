# frozen_string_literal: true

require 'net/http'
require 'socket'
require 'timeout'
require 'tempfile'

# A1 hotfix regression spec.
#
# Asserts the canonical lifecycle hook order across both worker models:
#
#   1. before_fork          (master, before any fork — and BEFORE the
#                            master-side bind on :share, so the contract
#                            matches :reuseport where the master never binds)
#   2. fork
#   3. on_worker_boot       (child, BEFORE the worker's listener is bound /
#                            adopted — so the operator hook runs against a
#                            process with no inbound socket)
#   4. ... worker accepts ...
#   5. on_worker_shutdown   (child, before exit)
#
# Pre-1.6.3 :share fired before_fork AFTER the master had bound its listening
# socket, while :reuseport (which never binds in master) fired it before any
# socket existed. That hand-off asymmetry is what A1 fixes.
RSpec.describe 'Lifecycle hook order across worker models' do
  WORKER_MODELS_UNDER_TEST = %i[share reuseport].freeze

  WORKER_MODELS_UNDER_TEST.each do |model|
    it "fires before_fork → on_worker_boot → on_worker_shutdown in order on :#{model}" do
      record_path = Tempfile.new(['hyperion-hooks', '.log']).tap(&:close).path
      File.write(record_path, '')

      rackup = Tempfile.new(['hello', '.ru'])
      rackup.write(<<~RU)
        run ->(_env) { [200, { 'content-type' => 'text/plain' }, ['ok']] }
      RU
      rackup.close

      # The hooks each append a single line to a shared file. Master appends
      # 'before_fork' once; each child appends 'on_worker_boot:<idx>' and
      # 'on_worker_shutdown:<idx>' around its accept loop. The before_fork
      # line additionally records whether the master's listener fd is bound
      # at hook time — that's the A1 invariant: in BOTH worker models the
      # operator's before_fork hook must see "no socket yet". On :reuseport
      # this is trivially true (master never binds). On :share, pre-A1, it
      # was false (master bound first, then fired before_fork).
      port_probe_path = Tempfile.new(['hyperion-port', '.txt']).tap(&:close).path

      cfg = Tempfile.new(['hooks', '.rb'])
      cfg.write(<<~CFG)
        record_path     = #{record_path.inspect}
        port_probe_path = #{port_probe_path.inspect}

        before_fork do
          probe_port = File.read(port_probe_path).strip.to_i
          listener_bound =
            begin
              s = TCPSocket.new('127.0.0.1', probe_port)
              s.close
              true
            rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL
              false
            rescue StandardError
              false
            end
          File.open(record_path, 'a') do |f|
            f.puts "before_fork:pid=\#{Process.pid}:listener_bound=\#{listener_bound}"
          end
        end

        on_worker_boot do |idx|
          File.open(record_path, 'a') do |f|
            f.puts "on_worker_boot:idx=\#{idx}:pid=\#{Process.pid}"
          end
        end

        on_worker_shutdown do |idx|
          File.open(record_path, 'a') do |f|
            f.puts "on_worker_shutdown:idx=\#{idx}:pid=\#{Process.pid}"
          end
        end
      CFG
      cfg.close

      bin = File.expand_path('../../bin/hyperion', __dir__)
      port = pick_free_port
      File.write(port_probe_path, port.to_s)

      env = { 'HYPERION_WORKER_MODEL' => model.to_s }
      pid = Process.spawn(env, bin, '-w', '2', '-p', port.to_s,
                          '-C', cfg.path, rackup.path,
                          out: '/dev/null', err: '/dev/null')

      wait_for_port(port, 15)
      response = Net::HTTP.get(URI("http://127.0.0.1:#{port}/"))
      expect(response).to eq('ok')

      # Wait for BOTH workers to fully boot — i.e. each has run its
      # on_worker_boot hook AND installed its SIGTERM trap (which it does
      # immediately after the hook in Worker#run). Without this, on slow
      # CI runners (notably macOS GitHub runners) we can race: master
      # binds the port → wait_for_port returns → one worker is still in
      # the boot→trap window when we send TERM → master forwards TERM
      # → that worker dies via default action with no shutdown hook fire
      # → spec fails with one shutdown line instead of two. We probe for
      # 2 boot lines as the readiness signal; the port-listen window is
      # not enough since on :share the master binds before any worker is
      # ready.
      wait_for_log_lines(record_path, /^on_worker_boot:/, 2, 30)

      Process.kill('TERM', pid)
      Timeout.timeout(30) { Process.waitpid(pid) }

      # Master reaps children before exiting, so by the time waitpid(pid)
      # returns the children have written their shutdown lines. Give the
      # filesystem a brief poll though — append+fsync ordering across
      # forks isn't guaranteed instantaneous on macOS APFS.
      wait_for_log_lines(record_path, /^on_worker_shutdown:/, 2, 10)

      lines = File.readlines(record_path).map(&:chomp).reject(&:empty?)

      # 1. Exactly one before_fork from the master.
      before_fork_lines = lines.grep(/^before_fork:/)
      expect(before_fork_lines.size).to eq(1),
                                        "expected one before_fork on :#{model}, got #{lines.inspect}"

      # 2. The master's listener must NOT yet be bound when before_fork runs.
      # That's the A1 alignment: same contract as :reuseport (where the
      # master never binds at all). Pre-A1 :share fired before_fork AFTER
      # bind_master_listener, so the probe would have connected.
      expect(before_fork_lines.first).to end_with('listener_bound=false'),
                                         "before_fork ran AFTER master listener was bound on :#{model} — pre-A1 ordering. Got: #{before_fork_lines.first}"

      # 3. Two on_worker_boot lines, one per worker, each in a DIFFERENT pid
      # from the master (i.e. they ran in the child, post-fork).
      boot_lines = lines.grep(/^on_worker_boot:/)
      expect(boot_lines.size).to eq(2), "expected two on_worker_boot on :#{model}, got #{lines.inspect}"

      master_pid = before_fork_lines.first[/pid=(\d+)/, 1].to_i
      boot_pids = boot_lines.map { |l| l[/pid=(\d+)/, 1].to_i }
      boot_pids.each do |bpid|
        expect(bpid).not_to eq(master_pid),
                            "on_worker_boot ran in master pid on :#{model} (#{boot_pids} vs master #{master_pid})"
      end
      expect(boot_pids.uniq.size).to eq(2),
                                     "expected two distinct worker pids on :#{model}, got #{boot_pids}"

      # 4. before_fork precedes every on_worker_boot in the recorded sequence.
      bf_index = lines.index(before_fork_lines.first)
      boot_lines.each do |l|
        expect(lines.index(l)).to be > bf_index,
                                  "on_worker_boot fired before before_fork on :#{model}: #{lines.inspect}"
      end

      # 5. Two on_worker_shutdown lines, each AFTER its corresponding boot.
      shutdown_lines = lines.grep(/^on_worker_shutdown:/)
      expect(shutdown_lines.size).to eq(2), "expected two on_worker_shutdown on :#{model}, got #{lines.inspect}"

      boot_pids.each do |worker_pid|
        boot_idx     = lines.index { |l| l.start_with?('on_worker_boot:')     && l.include?("pid=#{worker_pid}") }
        shutdown_idx = lines.index { |l| l.start_with?('on_worker_shutdown:') && l.include?("pid=#{worker_pid}") }
        expect(shutdown_idx).not_to be_nil, "no shutdown for worker pid #{worker_pid} on :#{model}"
        expect(shutdown_idx).to be > boot_idx,
                                "on_worker_shutdown ran before on_worker_boot for worker #{worker_pid} on :#{model}"
      end
    ensure
      rackup&.unlink
      cfg&.unlink
      File.unlink(record_path) if record_path && File.exist?(record_path)
      File.unlink(port_probe_path) if port_probe_path && File.exist?(port_probe_path)
      if pid
        begin
          Process.kill('KILL', pid)
        rescue StandardError
          nil
        end
        begin
          Process.waitpid(pid)
        rescue StandardError
          nil
        end
      end
    end
  end

  it 'fires on_worker_boot before listener bind in single-worker mode' do
    record_path = Tempfile.new(['hyperion-hooks-single', '.log']).tap(&:close).path
    File.write(record_path, '')
    port_probe_path = Tempfile.new(['hyperion-port-single', '.txt']).tap(&:close).path

    rackup = Tempfile.new(['hello', '.ru'])
    rackup.write(<<~RU)
      run ->(_env) { [200, { 'content-type' => 'text/plain' }, ['ok']] }
    RU
    rackup.close

    cfg = Tempfile.new(['hooks', '.rb'])
    cfg.write(<<~CFG)
      record_path     = #{record_path.inspect}
      port_probe_path = #{port_probe_path.inspect}

      on_worker_boot do |idx|
        probe_port = File.read(port_probe_path).strip.to_i
        listener_bound =
          begin
            s = TCPSocket.new('127.0.0.1', probe_port)
            s.close
            true
          rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL
            false
          rescue StandardError
            false
          end
        File.open(record_path, 'a') do |f|
          f.puts "on_worker_boot:idx=\#{idx}:listener_bound=\#{listener_bound}"
        end
      end

      on_worker_shutdown do |idx|
        File.open(record_path, 'a') { |f| f.puts "on_worker_shutdown:\#{idx}" }
      end
    CFG
    cfg.close

    bin = File.expand_path('../../bin/hyperion', __dir__)
    port = pick_free_port
    File.write(port_probe_path, port.to_s)
    pid = Process.spawn(bin, '-w', '1', '-p', port.to_s, '-C', cfg.path,
                        rackup.path, out: '/dev/null', err: '/dev/null')

    wait_for_port(port, 15)

    # Same readiness rationale as the cluster spec — wait for the
    # in-process "worker" to log its boot line before TERMing, so we
    # don't race the boot→signal-trap window on slow CI runners.
    wait_for_log_lines(record_path, /^on_worker_boot:/, 1, 30)

    Process.kill('TERM', pid)
    Timeout.timeout(15) { Process.waitpid(pid) }

    wait_for_log_lines(record_path, /^on_worker_shutdown:/, 1, 10)

    lines = File.readlines(record_path).map(&:chomp).reject(&:empty?)

    boot_lines = lines.grep(/^on_worker_boot:/)
    expect(boot_lines.size).to eq(1), "expected one on_worker_boot in single mode, got #{lines.inspect}"
    expect(boot_lines.first).to end_with('listener_bound=false'),
                                "on_worker_boot ran AFTER listener was bound in single mode: #{boot_lines.first}"

    shutdown_lines = lines.grep(/^on_worker_shutdown:/)
    expect(shutdown_lines.size).to eq(1)
  ensure
    rackup&.unlink
    cfg&.unlink
    File.unlink(record_path) if record_path && File.exist?(record_path)
    File.unlink(port_probe_path) if port_probe_path && File.exist?(port_probe_path)
    if pid
      begin
        Process.kill('KILL', pid)
      rescue StandardError
        nil
      end
      begin
        Process.waitpid(pid)
      rescue StandardError
        nil
      end
    end
  end

  def pick_free_port
    s = TCPServer.new('127.0.0.1', 0)
    port = s.addr[1]
    s.close
    port
  end

  def wait_for_port(port, timeout)
    deadline = Time.now + timeout
    loop do
      s = TCPSocket.new('127.0.0.1', port)
      s.close
      return
    rescue Errno::ECONNREFUSED
      raise "port #{port} not bound within #{timeout}s" if Time.now > deadline

      sleep 0.05
    end
  end

  # Poll a recorder log file until at least `expected_count` lines match
  # `pattern`, or `timeout` seconds elapse. Returns as soon as the count
  # is reached — does NOT wait the full timeout when the events arrive
  # quickly. Used to robustly synchronize on lifecycle-hook fire events
  # without sleeping a fixed budget; macOS GitHub runners are 2-3× slower
  # than typical dev hardware on fork/exec, so a generous ceiling is fine.
  def wait_for_log_lines(path, pattern, expected_count, timeout)
    deadline = Time.now + timeout
    loop do
      lines = File.readlines(path).map(&:chomp).reject(&:empty?)
      matching = lines.grep(pattern)
      return matching if matching.size >= expected_count

      if Time.now > deadline
        raise "expected #{expected_count} lines matching #{pattern.inspect} " \
              "within #{timeout}s; got #{matching.size}: #{lines.inspect}"
      end

      sleep 0.1
    end
  end
end
