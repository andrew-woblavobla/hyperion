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

      # Whether the C accept loop is available and the env didn't
      # disable it.
      def available?
        return false unless defined?(::Hyperion::Http::PageCache)
        return false unless ::Hyperion::Http::PageCache.respond_to?(:run_static_accept_loop)

        env = ENV['HYPERION_C_ACCEPT_LOOP']
        env.nil? || !%w[0 off false no].include?(env.downcase)
      end

      # Whether the route table is C-loop eligible: only `StaticEntry`
      # handlers, at least one of them, no dynamic handlers anywhere.
      def eligible_route_table?(route_table)
        return false unless route_table

        any_static = false
        route_table.instance_variable_get(:@routes).each_value do |path_table|
          path_table.each_value do |handler|
            return false unless handler.is_a?(::Hyperion::Server::RouteTable::StaticEntry)

            any_static = true
          end
        end
        any_static
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
