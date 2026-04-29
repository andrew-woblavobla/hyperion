# frozen_string_literal: true

# Build the hyperion_h2_codec Rust extension.
#
# Phase 6 (RFC 2.0 §3): native HPACK encode/decode + frame ser/de via
# a Rust crate. This extconf.rb is invoked by `gem install`; it shells
# out to `cargo build --release` and writes a Makefile that copies the
# resulting cdylib into `lib/hyperion_h2_codec/` so that
# `lib/hyperion/h2_codec.rb` can find it via Fiddle.
#
# Cargo is OPTIONAL. If it's missing, the extconf writes a stub
# Makefile that prints a friendly note and exits cleanly — Hyperion
# still ships and falls back to the existing Ruby HPACK path
# (`Hyperion::H2Codec.available?` returns false). Operators who want
# the perf bump install Rust via `rustup` and `gem pristine
# hyperion-rb` to rebuild.
#
# Cross-platform notes:
#   * Linux + GNU libc: cargo emits `libhyperion_h2_codec.so`.
#   * macOS:           `libhyperion_h2_codec.dylib`.
#   * The Ruby loader (Fiddle) probes both extensions in order, so we
#     copy whichever cargo produced into the gem's lib_dir under both
#     names where convenient.

require 'mkmf'
require 'fileutils'
require 'rbconfig'

ext_dir = __dir__
crate_dir = ext_dir
target_dir = File.join(crate_dir, 'target', 'release')
gem_lib_dir = File.expand_path('../../lib/hyperion_h2_codec', __dir__)

cargo_present = system('cargo --version > /dev/null 2>&1')

if cargo_present
  warn '[hyperion_h2_codec] cargo detected — building native HPACK extension'
  Dir.chdir(crate_dir) do
    ok = system('cargo build --release')
    unless ok
      warn '[hyperion_h2_codec] cargo build failed; falling back to pure-Ruby HPACK path'
      cargo_present = false
    end
  end
end

FileUtils.mkdir_p(gem_lib_dir)

if cargo_present
  candidates = %w[libhyperion_h2_codec.dylib libhyperion_h2_codec.so]
  found = candidates.find { |c| File.exist?(File.join(target_dir, c)) }
  if found
    src = File.join(target_dir, found)
    dst = File.join(gem_lib_dir, found)
    FileUtils.cp(src, dst)
    warn "[hyperion_h2_codec] installed #{dst}"
  else
    warn '[hyperion_h2_codec] cargo finished but no cdylib artifact found; falling back'
    cargo_present = false
  end
end

# Always emit a Makefile — gem install protocol expects one. The body
# is a no-op when cargo isn't present so `make` exits 0 and gem
# install completes.
File.open(File.join(ext_dir, 'Makefile'), 'w') do |f|
  f.puts 'all:'
  f.puts "\t@echo \"[hyperion_h2_codec] no-op make (cargo handled the build)\""
  f.puts 'clean:'
  f.puts "\t@rm -rf target"
  f.puts 'install:'
  f.puts "\t@echo \"[hyperion_h2_codec] no-op install (artifact already in lib/)\""
end
