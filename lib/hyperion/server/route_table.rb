# frozen_string_literal: true

require 'stringio'

module Hyperion
  class Server
    # 2.10-D — direct-dispatch route registry.  Mirrors agoo's
    # `Agoo::Server.handle(:GET, "/hello", handler)` design: a lookup
    # table indexed by HTTP method then exact-match path.  When a
    # match hits inside `Connection#serve` (after parse, before the
    # Rack adapter), the dispatcher skips the env-hash build, the
    # middleware chain, and the body-iteration overhead — the
    # handler is called directly with a `Hyperion::Request` value
    # object and returns either a `[status, headers, body]` Rack
    # tuple or a sentinel that points at a pre-built static
    # response buffer (the `handle_static` path, where the response
    # bytes are baked at registration time so the hot path is one
    # `socket.write` syscall and zero Ruby allocation past the
    # Connection ivars).
    #
    # The table is per-process: forked workers each inherit a copy
    # of the parent's table at fork time (no IPC, no shared memory)
    # so registrations made before `Server.start` propagate to every
    # worker via copy-on-write.  Registrations made AFTER fork (e.g.
    # from `on_worker_boot`) only affect the calling worker — by
    # design, this is the operator's escape hatch for per-worker
    # routing.  The hot-path lookup is a two-Hash-key access (O(1));
    # write paths are guarded by a Mutex so a registration racing
    # with an in-flight request lookup is safe.
    #
    # Mutability invariant: registrations replace any prior entry
    # for the same `(method, path)` tuple — last writer wins.  No
    # delete API for now (operator restarts to clear), keeps the
    # public surface minimal.
    class RouteTable
      # The seven HTTP methods agoo's `Server.handle` accepts.  We
      # match agoo's surface verbatim so apps porting their
      # registrations across servers don't have to relearn the
      # matrix.  `OPTIONS` is included for CORS preflight handlers
      # (commonly registered as direct routes since they have no
      # business model).
      KNOWN_METHODS = %i[GET POST PUT DELETE HEAD PATCH OPTIONS].freeze

      # 2.10-D — sentinel result returned by `Server.handle_static`'s
      # internal handler.  When `Connection#serve` sees it, the writer
      # short-circuits to a single `socket.write(buf)` of the
      # pre-built response buffer — no header build, no body
      # iteration.  Wrapping the buffer in a small struct (rather
      # than returning the raw String from `handle`) keeps the
      # `[status, headers, body]` shape contract visible while
      # giving the dispatcher a single `is_a?` branch to engage the
      # one-syscall fast path.
      # 2.10-F adds `headers_len` so the C fast path
      # (`PageCache.serve_request`) can write the headers-only prefix
      # for HEAD requests without reparsing the buffer.  Defaults to
      # `buffer.bytesize` for back-compat with callers that
      # constructed StaticEntry the 2.10-D way (3 args, no body
      # split) — those entries fall back to writing the whole buffer
      # on HEAD too, which is RFC-correct (HEAD MAY include the body
      # so long as Content-Length matches; the spec only forbids the
      # SERVER from sending body bytes the client didn't ask for).
      #
      # 2.17-A (Hot Path Task 2) adds two more fields so the C-loop
      # writer can mem-splice a per-second-cached HTTP `Date:` header
      # into a pre-built keep-alive response without rebuilding it
      # from scratch:
      #   * `prebuilt_keepalive_bytes` — frozen ASCII-8BIT String of
      #     the full HTTP/1.1 wire response (status line + Server +
      #     Content-Type + Content-Length + Connection: keep-alive +
      #     Date placeholder + body) with a 29-byte 'X' run reserved
      #     at `prebuilt_date_offset`.  The placeholder is overwritten
      #     in a per-write scratch buffer (NEVER in this frozen
      #     String) by the C splice helper before the syscall fires.
      #   * `prebuilt_date_offset` — Integer byte offset of the first
      #     placeholder byte within `prebuilt_keepalive_bytes`.  Zero
      #     means "no Date placeholder; do not splice".  29 bytes is
      #     the canonical RFC 7231 imf-fixdate length.
      # Existing callers that construct StaticEntry with 3 or 4 args
      # see nil for these new fields and the C side falls through to
      # the un-spliced fast path it has used since 2.10-F.
      StaticEntry = Struct.new(:method, :path, :buffer, :headers_len,
                                :prebuilt_keepalive_bytes,
                                :prebuilt_date_offset) do
        # Returns the pre-built response bytes ready for one
        # `socket.write` call.  Always frozen.
        def response_bytes
          buffer
        end

        # 2.10-F — StaticEntry responds to `#call` so it can be
        # registered directly in the route table (instead of via a
        # closure wrapping it).  Returning `self` keeps the
        # `[status, headers, body]` contract: `dispatch_direct!`'s
        # is_a?(StaticEntry) branch handles the wire write.  Pre-
        # 2.10-F callers that registered via
        # `Server.handle_static` still work — that registration
        # path now stores the entry directly and the route table's
        # `respond_to?(:call)` invariant is preserved.
        def call(_request)
          self
        end

        # 2.10-F — bytes-count of the headers-only prefix.  Used by
        # callers that reach the StaticEntry directly (specs, custom
        # writers); the C fast path reads the C-side `headers_len`
        # mirror that `PageCache.register_prebuilt` records.
        def headers_bytesize
          headers_len || buffer.bytesize
        end
      end

      # 2.14-A — wrapper for a Rack-style block registered via
      # `Server.handle(:GET, '/path') { |env| [...] }`.  Differs from
      # `StaticEntry` in that the response is computed per-request
      # rather than baked at registration time — but the route table
      # entry shape is uniform, so the C accept loop can branch on
      # `is_a?(DynamicBlockEntry)` AFTER the StaticEntry check and
      # invoke the block via the registered C-loop dispatch helper.
      #
      # The struct holds:
      #   * `method` — request-method symbol (`:GET`, `:POST`, ...)
      #   * `path`   — exact-match path String (frozen)
      #   * `block`  — the registered Proc / lambda; receives a Rack
      #     env hash and must return a `[status, headers, body]`
      #     triple per the Rack spec.  The C accept loop hands it a
      #     populated env via the `Adapter::Rack.dispatch_for_c_loop`
      #     helper; the block sees the same env shape Rack apps
      #     normally see (HTTP_*, REQUEST_METHOD, PATH_INFO, etc.).
      #
      # Calling the entry directly (the legacy fall-through path used
      # when the C accept loop is NOT engaged — TLS listeners, mixed
      # tables, operator escape hatch via `HYPERION_C_ACCEPT_LOOP=0`)
      # delegates straight to the block with a freshly-built env via
      # the existing `Adapter::Rack#call` machinery.  The Connection
      # path's direct-route dispatcher already handles
      # `respond_to?(:call)` entries by invoking them with a
      # `Hyperion::Request` value object — we route through that
      # surface so the legacy fallback stays bit-identical to a
      # 2.13-shape `Server.handle` registration.
      DynamicBlockEntry = Struct.new(:method, :path, :block) do
        # Legacy direct-route surface: `RouteTable#lookup` → handler →
        # `handler.call(request)` returning a `[status, headers, body]`
        # triple. Used by the Connection path when the C accept loop is
        # disengaged (TLS, mixed tables). We hand the block a minimal
        # env hash so it sees the same Rack-style API regardless of
        # which dispatch shape served the request.
        def call(request)
          env = build_legacy_env(request)
          block.call(env)
        end

        private

        def build_legacy_env(request)
          headers = request.respond_to?(:headers) ? (request.headers || {}) : {}
          env = {
            'REQUEST_METHOD' => request.method,
            'PATH_INFO' => request.path,
            'QUERY_STRING' => request.query_string.to_s,
            'SERVER_NAME' => 'localhost',
            'SERVER_PORT' => '80',
            'rack.input' => StringIO.new(request.body.to_s),
            'rack.errors' => $stderr,
            'rack.url_scheme' => 'http'
          }
          headers.each do |name, value|
            key = "HTTP_#{name.to_s.upcase.tr('-', '_')}"
            env[key] = value
          end
          env
        end
      end

      def initialize
        # Per-method Hash so the lookup is `@routes[:GET][path]`
        # — two integer-keyed-Hash hits.  Pre-allocate the seven
        # slots so the request hot path never lazily creates an
        # entry under a misspelled method (we just miss).
        @routes = KNOWN_METHODS.each_with_object({}) { |m, h| h[m] = {} }
        @mutex  = Mutex.new
      end

      # Register a direct-dispatch handler for the given method +
      # path.  `handler` must respond to `#call(request)` and return
      # either:
      #
      #   * a `[status, headers, body]` Rack tuple — the dispatcher
      #     writes it via the standard ResponseWriter (no env hash,
      #     no middleware), or
      #   * a `StaticEntry` (built only via `Server.handle_static`)
      #     — the dispatcher emits the pre-built bytes in one
      #     write syscall.
      #
      # `method_sym` is upper-cased before lookup so callers may pass
      # `:get` or `'get'` interchangeably with `:GET`.
      def register(method_sym, path, handler)
        method_key = normalize_method(method_sym)
        raise ArgumentError, "unknown method #{method_sym.inspect}" unless KNOWN_METHODS.include?(method_key)
        raise ArgumentError, 'path must be a String' unless path.is_a?(String)
        raise ArgumentError, 'handler must respond to #call' unless handler.respond_to?(:call)

        @mutex.synchronize { @routes[method_key][path.dup.freeze] = handler }
        handler
      end

      # Hot-path lookup.  `method_str` is the request method as the
      # parser produced it (a String like `'GET'`); `path` is the
      # request path String.  Returns the registered handler or nil.
      #
      # No mutex on the read side — Ruby Hash reads under MRI are
      # safe against a concurrent write that's mutex-guarded
      # (the GVL pins the writer during the bucket update), and
      # the cost of a Mutex acquire on every request would defeat
      # the whole point of the fast path.
      def lookup(method_str, path)
        method_key = METHOD_LOOKUP[method_str] || normalize_method(method_str)
        table = @routes[method_key]
        return nil unless table

        table[path]
      end

      # Inspection helper — returns the count of registered routes
      # across all methods.  Used by specs and the bench harness
      # to assert registrations took effect.
      def size
        @routes.values.sum(&:size)
      end

      # Clear all registrations.  Test / spec seam — production
      # code restarts the process to drop routes.
      def clear
        @mutex.synchronize { @routes.each_value(&:clear) }
        nil
      end

      private

      # Pre-built lookup for the seven canonical method strings the
      # parser emits.  Skips the Symbol allocation + upcase that
      # `normalize_method` does for unrecognised inputs.  Frozen so
      # the table itself is shared across all RouteTable instances
      # (one allocation, process-wide).
      METHOD_LOOKUP = {
        'GET' => :GET,
        'POST' => :POST,
        'PUT' => :PUT,
        'DELETE' => :DELETE,
        'HEAD' => :HEAD,
        'PATCH' => :PATCH,
        'OPTIONS' => :OPTIONS
      }.freeze

      def normalize_method(value)
        case value
        when Symbol
          KNOWN_METHODS.include?(value) ? value : value.to_s.upcase.to_sym
        else
          value.to_s.upcase.to_sym
        end
      end
    end
  end
end
