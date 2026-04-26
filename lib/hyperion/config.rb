# frozen_string_literal: true

module Hyperion
  # Mutable configuration container — populated by the DSL evaluator
  # (Hyperion::Config.load) and then read by CLI / Server / Master / Worker /
  # Connection / Logger.
  #
  # All settings have safe defaults that match the per-class DEFAULT_* constants
  # so that running Hyperion without a config file works identically to the
  # pre-rc14 behaviour.
  class Config
    DEFAULTS = {
      host: '127.0.0.1',
      port: 9292,
      workers: 1,
      thread_count: 5,
      tls_cert: nil,
      tls_key: nil,
      read_timeout: 30,
      idle_keepalive: 5,
      graceful_timeout: 30,
      max_header_bytes: 64 * 1024,
      max_body_bytes: 16 * 1024 * 1024,
      log_level: nil, # nil → Logger picks from env / default
      log_format: nil, # nil → Logger picks via auto rule
      log_requests: nil, # nil → Hyperion.log_requests? (default true)
      fiber_local_shim: false,
      yjit: nil # nil → auto: enable on production/staging; true/false to force.
    }.freeze

    HOOKS = %i[before_fork on_worker_boot on_worker_shutdown].freeze

    attr_accessor(*DEFAULTS.keys)
    attr_reader(*HOOKS)

    def initialize
      DEFAULTS.each { |k, v| public_send(:"#{k}=", v) }
      HOOKS.each { |h| instance_variable_set(:"@#{h}", []) }
    end

    HOOKS.each do |hook|
      define_method(:"add_#{hook}") do |&block|
        instance_variable_get(:"@#{hook}") << block if block
      end
    end

    # Load a Ruby DSL config file. Returns the populated Config.
    # Path is the operator-supplied --config argument; we evaluate it in a
    # DSL context that maps method calls to attribute setters.
    def self.load(path)
      cfg = new
      contents = File.read(path)
      DSL.new(cfg).instance_eval(contents, path)
      cfg
    end

    # Apply CLI overrides on top of an existing config. Only non-nil values
    # in `overrides` are applied — preserves the precedence ordering
    # (CLI > env > config file > default).
    def merge_cli!(overrides)
      overrides.each do |key, value|
        next if value.nil?

        public_send(:"#{key}=", value) if respond_to?(:"#{key}=")
      end
      self
    end

    # DSL receiver. Each method call on the DSL maps to a Config setter or
    # to a hook registration. Unknown methods raise NoMethodError so typos
    # surface immediately at boot rather than as silent ignores.
    class DSL
      def initialize(config)
        @config = config
      end

      # `bind` is the Puma-style alias for `host` — operators expect it.
      def bind(value)
        @config.host = value
      end

      Config::DEFAULTS.each_key do |key|
        define_method(key) do |value|
          @config.public_send(:"#{key}=", value)
        end
      end

      Config::HOOKS.each do |hook|
        define_method(hook) do |&block|
          @config.public_send(:"add_#{hook}", &block)
        end
      end

      # `tls_cert_path` / `tls_key_path` are convenience aliases that read
      # the file off disk so the DSL stays terse. The parsed cert/key are
      # stored on the config and Server consumes them directly.
      def tls_cert_path(path)
        require 'openssl'
        @config.tls_cert = OpenSSL::X509::Certificate.new(File.read(path))
      end

      def tls_key_path(path)
        require 'openssl'
        @config.tls_key = OpenSSL::PKey.read(File.read(path))
      end
    end
  end
end
