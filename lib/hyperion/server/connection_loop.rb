# frozen_string_literal: true

module Hyperion
  class Server
    # 2.12-C — Connection lifecycle in C.
    #
    # Engaged by `Server#start_raw_loop` when ALL of the following hold:
    #
    #   * The listener is plain TCP (no TLS, no h2 ALPN dance).
    #   * The route table has at least one `RouteTable::StaticEntry`
    #     registration (i.e. `Server.handle_static` was called).
    #   * The route table has NO non-StaticEntry registrations
    #     (any `Server.handle(:GET, '/api', dynamic_handler)` disables
    #     the C path; the C loop only knows how to write prebuilt
    #     responses).
    #   * The `HYPERION_C_ACCEPT_LOOP` env knob is not set to `"0"` /
    #     `"off"` (operator escape hatch for debug).
    #
    # On engage, the Ruby accept loop is *not* run for this listener;
    # `Hyperion::Http::PageCache.run_static_accept_loop` drives the
    # accept-and-serve loop entirely in C and only re-enters Ruby for:
    #
    #   1. Per-request lifecycle hooks
    #      (`Runtime#fire_request_start` / `fire_request_end`), gated
    #      by a single C-side integer flag so the no-hook hot path
    #      stays one syscall.
    #   2. Connection handoff: requests that don't match a `StaticEntry`
    #      (or are malformed, h2/upgrade, or carry a body) are passed
    #      back as `(fd, partial_buffer)` — Ruby resumes ownership of
    #      the fd and dispatches via the regular `Connection` path.
    #
    # The wiring lives in this module so the conditional logic stays
    # out of the Server hot-path entry methods.
    module ConnectionLoop
      module_function

      # 2.14-B — bound applied to the wake-connect dial inside
      # `Server#stop`. The listener is local — a successful connect
      # is sub-millisecond — so the cap exists purely as a sanity
      # bound for the pathological case where the listener was
      # already torn down (Errno::ECONNREFUSED is fast) or the
      # kernel netstack is somehow stuck (e.g. CI under heavy load).
      WAKE_CONNECT_TIMEOUT_SECONDS = 1.0

      # 2.14-B — number of wake-connect dials issued per `Server#stop`.
      # In single-server / `:share` cluster mode (Darwin/BSD), one dial
      # is enough — the listener is shared and any wake races to a
      # parked accept call. In `:reuseport` cluster mode (Linux), the
      # kernel hashes incoming SYNs across each worker's per-process
      # listener fd; one dial may hash to a sibling whose stop hasn't
      # progressed, leaving THIS worker's accept thread parked. K=8
      # drops the miss probability to <1% for realistic worker counts
      # (≤32 workers per host) and adds at most ~8ms to a stop call —
      # well below the master-side `graceful_timeout` (30s default).
      WAKE_CONNECT_BURST = 8

      # 2.14-B — Wake any thread parked in `accept(2)` on the listener
      # bound at `host:port` by dialing one (or `count`) throwaway TCP
      # connections.
      #
      # Background. On Linux ≥ 6.x, calling `close()` on a listening
      # socket from one thread does NOT interrupt another thread that
      # is currently blocked in `accept(2)` on that same fd — the
      # kernel silently dropped the close-wake guarantee that
      # `Server#stop` (and 2.13-C's spec teardown) had relied on.
      # Without this helper, the C accept loop stays parked until a
      # real connection arrives, which during a SIGTERM-driven graceful
      # shutdown means "until SIGKILL".
      #
      # The fix is structural: dial a throwaway TCP connection at the
      # listener's bound address. The accept call returns with the new
      # fd, the C loop services it (a 0-byte read drops it), then
      # re-checks `hyp_cl_stop` between accepts and exits cleanly. The
      # 2.13-C connection_loop_spec helper does the same thing in spec
      # land — this is the production-side mirror.
      #
      # Burst semantics. With SO_REUSEPORT (Linux cluster mode), the
      # kernel hashes each SYN to one of the N still-open per-worker
      # listeners. A single dial from worker A may hash to worker B —
      # leaving A's parked accept un-woken. Dialing K times (default
      # `WAKE_CONNECT_BURST`) drives the miss probability down to
      # negligible for typical worker counts.
      #
      # Failure-tolerant by construction:
      # * `Errno::ECONNREFUSED` — listener already closed (the close
      #   raced ahead of us). Nothing to wake; bail out of the burst
      #   so we don't spend the timeout budget on doomed dials.
      # * `Errno::EADDRNOTAVAIL` — interface gone. Same.
      # * Connect timeout — kernel netstack is stuck; we tried, the
      #   caller's `thread.join(timeout)` will surface the symptom.
      # * Any other socket error — log nothing (we may be running
      #   inside a signal handler thread); just swallow.
      def wake_listener(host, port, connect_timeout: WAKE_CONNECT_TIMEOUT_SECONDS,
                        count: 1)
        return unless host && port
        return if count <= 0

        count.times do
          break unless dial_wake_once(host, port, connect_timeout)
        end
        nil
      end

      # 2.14-B — single dial. Returns true on success (continue
      # bursting), false on a "listener gone" outcome (abort the burst
      # so we don't waste the timeout budget on N×ECONNREFUSED).
      def dial_wake_once(host, port, connect_timeout)
        ::Socket.tcp(host, port, connect_timeout: connect_timeout, &:close)
        true
      rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL, Errno::EHOSTUNREACH,
             Errno::ENETUNREACH
        # Listener gone — no point retrying, the kernel will refuse
        # every dial in this burst the same way.
        false
      rescue Errno::ETIMEDOUT, Errno::ECONNRESET, Errno::EPIPE,
             Errno::EBADF, IOError, SocketError
        # Transient — keep bursting in case a later dial races into a
        # still-open sibling listener (REUSEPORT cluster mode).
        true
      end
      private_class_method :dial_wake_once

      # Whether the C accept loop is available and the env didn't
      # disable it.
      def available?
        return false unless defined?(::Hyperion::Http::PageCache)
        return false unless ::Hyperion::Http::PageCache.respond_to?(:run_static_accept_loop)

        env = ENV['HYPERION_C_ACCEPT_LOOP']
        env.nil? || !%w[0 off false no].include?(env.downcase)
      end

      # 2.12-D — whether to engage the io_uring accept loop variant
      # over the 2.12-C `accept4` loop. All four conditions must hold:
      #
      #   1. Operator opted in via `HYPERION_IO_URING_ACCEPT=1`. This
      #      is OFF by default for 2.12.0 — flipping the default to ON
      #      is a 2.13 decision after production-soak.
      #   2. The C ext was compiled with `HAVE_LIBURING` (probed at
      #      gem-install time via `extconf.rb` — needs `liburing-dev`
      #      headers). Builds without it ship the stub method that
      #      returns `:unavailable` regardless of the env var.
      #   3. `Hyperion::Http::PageCache.run_static_io_uring_loop` is
      #      defined (paranoia: the symbol always exists on builds
      #      that loaded the C ext, but the check keeps us from
      #      NameError'ing on partial installs).
      #   4. A liburing runtime probe — opening a tiny ring with
      #      `io_uring_queue_init`. The probe lives inside the C
      #      method itself (`run_static_io_uring_loop` returns
      #      `:unavailable` if `io_uring_queue_init` fails); we
      #      don't pre-probe here because that would require holding
      #      a ring open across the eligibility check, and the
      #      penalty for "engaged but probe-fail at run time" is
      #      one cheap fall-through to the `accept4` path.
      def io_uring_eligible?
        return false unless available?
        return false unless ::Hyperion::Http::PageCache.respond_to?(:run_static_io_uring_loop)
        return false unless ::Hyperion::Http::PageCache.respond_to?(:io_uring_loop_compiled?) &&
                            ::Hyperion::Http::PageCache.io_uring_loop_compiled?

        env = ENV['HYPERION_IO_URING_ACCEPT']
        return false unless env

        %w[1 on true yes].include?(env.downcase)
      end

      # Whether the route table is C-loop eligible: every registered
      # entry is either a `StaticEntry` (2.12-C path) or a
      # `DynamicBlockEntry` (2.14-A path), and the table has at least
      # one of either. Legacy `Server.handle(method, path, handler)`
      # registrations (where `handler` takes a `Hyperion::Request`)
      # disable the C path — those still flow through `Connection#serve`.
      def eligible_route_table?(route_table)
        return false unless route_table

        any_eligible = false
        route_table.instance_variable_get(:@routes).each_value do |path_table|
          path_table.each_value do |handler|
            return false unless eligible_entry?(handler)

            any_eligible = true
          end
        end
        any_eligible
      end

      # 2.14-A — predicate split out so specs and the engagement check
      # can introspect single entries. Lives here (rather than on the
      # entry classes) so the eligibility surface stays in one place.
      def eligible_entry?(handler)
        handler.is_a?(::Hyperion::Server::RouteTable::StaticEntry) ||
          handler.is_a?(::Hyperion::Server::RouteTable::DynamicBlockEntry)
      end

      # Build a lifecycle callback that, when invoked from the C loop
      # with `(method_str, path_str)`, fires the runtime's
      # `fire_request_start` / `fire_request_end` hooks against a
      # minimal `Hyperion::Request` value object. `env=nil` and the
      # response slot carries the `:c_static` symbol (just a marker —
      # the wire write already happened in C and we have no
      # `[status, headers, body]` tuple to hand back).
      #
      # The proc captures `runtime` so multi-tenant deployments with
      # per-Server runtimes route hooks to the right observer
      # registry. Allocation cost: one Request per request when
      # hooks are active. The C loop only invokes this callback when
      # `lifecycle_active?` is true; the no-hook path pays nothing.
      def build_lifecycle_callback(runtime)
        lambda do |method_str, path_str|
          request = ::Hyperion::Request.new(
            method: method_str,
            path: path_str,
            query_string: nil,
            http_version: 'HTTP/1.1',
            headers: {},
            body: nil
          )
          if runtime.has_request_hooks?
            runtime.fire_request_start(request, nil)
            runtime.fire_request_end(request, nil, :c_static, nil)
          end
          nil
        rescue StandardError
          # Hook errors are already swallowed inside `Runtime#fire_*`;
          # this rescue catches Request allocation oddities so a
          # misbehaving observer can't take down the C loop.
          nil
        end
      end

      # Build the handoff callback the C loop invokes when a
      # connection's first request can't be served from the static
      # cache. Receives `(fd, partial_buffer_or_nil)` — Ruby owns
      # the fd from that point on. We wrap the fd in a `Socket`
      # (so `apply_timeout` and the rest of the Connection path see
      # the same surface they always see) and dispatch through the
      # server's existing `dispatch_handed_off` helper.
      def build_handoff_callback(server)
        lambda do |fd, partial|
          server.send(:dispatch_handed_off, fd, partial)
        rescue StandardError => e
          server.send(:runtime_logger).warn do
            { message: 'C loop handoff dispatch failed',
              error: e.message, error_class: e.class.name }
          end
          # Always close the fd if dispatch raised — Ruby owns it.
          begin
            require 'socket'
            ::Socket.for_fd(fd).close
          rescue StandardError
            nil
          end
        end
      end
    end
  end
end
