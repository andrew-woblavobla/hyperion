# frozen_string_literal: true

# Build the hyperion_io_uring Rust extension (2.3-A).
#
# Mirrors `ext/hyperion_h2_codec/extconf.rb`: shells out to
# `cargo build --release`, drops the resulting cdylib into
# `lib/hyperion_io_uring/`, and writes a no-op Makefile so `gem
# install` succeeds.
#
# Cargo is OPTIONAL. If it's missing, the extconf writes a stub
# Makefile that prints a friendly note and exits cleanly — Hyperion
# still ships and `Hyperion::IOUring.supported?` returns false on
# both Darwin (no kernel support anyway) and Linux hosts that lack
# Rust. Operators who want the perf bump install Rust via `rustup`
# and `gem pristine hyperion-rb` to rebuild.
#
# Cross-platform notes:
#   * Linux + GNU libc: cargo emits `libhyperion_io_uring.so`.
#   * macOS:           `libhyperion_io_uring.dylib`.
#   * The Linux-only `io-uring` crate is gated via Cargo
#     `target.'cfg(target_os = "linux")'`, so the macOS build
#     compiles cleanly but every entry point returns -ENOSYS. The
#     Ruby loader checks the OS first via `IOUring.supported?` and
#     never reaches those stubs.

require 'mkmf'
require 'fileutils'
require 'rbconfig'

ext_dir = __dir__
crate_dir = ext_dir
target_dir = File.join(crate_dir, 'target', 'release')
gem_lib_dir = File.expand_path('../../lib/hyperion_io_uring', __dir__)

cargo_present = system('cargo --version > /dev/null 2>&1')

if cargo_present
  warn '[hyperion_io_uring] cargo detected — building io_uring accept extension'
  Dir.chdir(crate_dir) do
    ok = system('cargo build --release')
    unless ok
      warn '[hyperion_io_uring] cargo build failed; falling back to epoll accept path'
      cargo_present = false
    end
  end
end

FileUtils.mkdir_p(gem_lib_dir)

if cargo_present
  candidates = %w[libhyperion_io_uring.dylib libhyperion_io_uring.so]
  found = candidates.find { |c| File.exist?(File.join(target_dir, c)) }
  if found
    src = File.join(target_dir, found)
    dst = File.join(gem_lib_dir, found)
    FileUtils.cp(src, dst)
    warn "[hyperion_io_uring] installed #{dst}"
  else
    warn '[hyperion_io_uring] cargo finished but no cdylib artifact found; falling back'
    cargo_present = false
  end
end

# Always emit a Makefile — gem install protocol expects one. The body
# is a no-op when cargo isn't present so `make` exits 0 and gem
# install completes.
File.open(File.join(ext_dir, 'Makefile'), 'w') do |f|
  f.puts 'all:'
  f.puts "\t@echo \"[hyperion_io_uring] no-op make (cargo handled the build)\""
  f.puts 'clean:'
  f.puts "\t@rm -rf target"
  f.puts 'install:'
  f.puts "\t@echo \"[hyperion_io_uring] no-op install (artifact already in lib/)\""
end
