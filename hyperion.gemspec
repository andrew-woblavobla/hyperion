# frozen_string_literal: true

require_relative 'lib/hyperion/version'

Gem::Specification.new do |spec|
  spec.name          = 'hyperion-rb'
  spec.version       = Hyperion::VERSION
  spec.authors       = ['Andrey Lobanov']
  spec.email         = ['woblavobla@gmail.com']
  spec.summary       = 'High-performance Ruby HTTP server (Falcon-core + Puma-skin)'
  spec.description   = 'A Ruby HTTP server combining Falcon-class fiber concurrency with Puma-class compatibility.'
  spec.homepage      = 'https://github.com/andrew-woblavobla/hyperion'
  spec.license       = 'MIT'
  spec.required_ruby_version = '>= 3.3.0'

  spec.metadata = {
    'homepage_uri'    => 'https://github.com/andrew-woblavobla/hyperion',
    'source_code_uri' => 'https://github.com/andrew-woblavobla/hyperion',
    'bug_tracker_uri' => 'https://github.com/andrew-woblavobla/hyperion/issues',
    'changelog_uri'   => 'https://github.com/andrew-woblavobla/hyperion/blob/main/CHANGELOG.md'
  }

  spec.files = Dir[
    'lib/**/*.rb',
    'bin/*',
    'ext/**/*.{rb,c,h,rs}',
    'ext/hyperion_h2_codec/Cargo.toml',
    'ext/hyperion_h2_codec/Cargo.lock',
    'CHANGELOG.md',
    'README.md',
    'LICENSE'
  ]
  spec.bindir = 'bin'
  spec.executables = ['hyperion']
  spec.require_paths = ['lib']
  # Two extensions:
  #   * `hyperion_http` — llhttp + sendfile + Rack-env builder (C, since 1.x).
  #   * `hyperion_h2_codec` — Rust HPACK + frame primitives (new in 2.0).
  #     The Rust extension's extconf.rb gracefully handles a missing
  #     cargo toolchain by writing a no-op Makefile, so `gem install`
  #     succeeds on hosts without Rust and Hyperion falls back to
  #     `protocol-http2`'s Ruby HPACK at runtime.
  spec.extensions = [
    'ext/hyperion_http/extconf.rb',
    'ext/hyperion_h2_codec/extconf.rb'
  ]

  spec.add_dependency 'rack', '>= 3.0', '< 4.0'
  spec.add_dependency 'async', '>= 2.0', '< 3.0'
  spec.add_dependency 'protocol-http2', '~> 0.26'
  # Pinned to < 4.0 because openssl 4.0 froze
  # OpenSSL::SSL::SSLContext::DEFAULT_PARAMS. Apps that mutate that hash
  # (notably the AWS SDK initializer pattern that sets `:ciphers`) crash on
  # boot under openssl 4. Falcon only requires `>= 3.0`, so this pin is
  # compatible with the rest of the gem graph.
  spec.add_dependency 'openssl', '>= 3.0', '< 4.0'
  # WS-2 (2.1.0) uses `base64` for RFC 6455 Sec-WebSocket-Accept. Ruby 3.4
  # promoted base64 from stdlib to a bundled gem, so we depend on it
  # explicitly so `require 'base64'` works on 3.4+ without the user adding
  # it to their own Gemfile.
  spec.add_dependency 'base64', '~> 0.2'

  spec.add_development_dependency 'rspec', '~> 3.13'
  spec.add_development_dependency 'rake', '~> 13.0'
  spec.add_development_dependency 'rake-compiler', '~> 1.2'
end
