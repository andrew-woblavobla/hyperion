# frozen_string_literal: true

require 'mkmf'

# llhttp source files vendored under ext/hyperion_http/llhttp/.
# We compile them in-tree (single static unit) rather than linking a
# system library, so the gem builds standalone on any host with a C
# compiler + Ruby headers.
#
# 1.7.0 Phase 1 adds sendfile.c — a sibling translation unit that owns
# Hyperion::Http::Sendfile. Linked into the same .bundle/.so as parser.c
# (single `require` for both), with platform-specific kernel calls
# guarded inside the C source rather than at extconf time so we still
# build cleanly on platforms where neither sendfile(2) nor splice(2)
# is available (the C source raises NotImplementedError at call time).
$srcs = %w[
  parser.c
  sendfile.c
  page_cache.c
  io_uring_loop.c
  websocket.c
  h2_codec_glue.c
  llhttp.c
  api.c
  http.c
]
$VPATH << '$(srcdir)/llhttp'
$INCFLAGS << ' -I$(srcdir)/llhttp'
$CFLAGS << ' -O2 -fno-strict-aliasing'

# Probe for sendfile/splice headers so the C source can use the right
# branch with #ifdef. mkmf's have_header writes -DHAVE_<NAME> macros
# that sendfile.c can consult if we want a finer split later; for now
# the source already picks the path off __linux__ / __APPLE__ /
# __FreeBSD__ defines that the toolchain provides automatically.
have_header('sys/sendfile.h') # Linux: sendfile64
have_header('sys/uio.h')      # BSD/Darwin sendfile + Linux iovec plumbing
have_header('sys/socket.h')

# 2.4-A: h2_codec_glue.c calls dlopen/dlsym to wire the Rust HPACK
# cdylib without going through Fiddle on the per-call hot path. macOS
# ships dlopen in libSystem (no extra link flag needed); Linux glibc
# requires `-ldl` (musl rolls dlopen into libc, but `have_library`
# returns true on both because the symbol resolves either way).
have_header('dlfcn.h')
have_library('dl', 'dlopen')

# 2.12-D — io_uring accept loop (Linux 5.x).
#
# Soft-optional dependency: if `liburing` is installed at compile time
# (Ubuntu/Debian: `apt install liburing-dev`; Fedora: `dnf install
# liburing-devel`; Arch: `pacman -S liburing`), we build the io_uring
# accept-loop variant. If it's not, the C ext compiles cleanly without
# it and the Ruby caller falls through to the 2.12-C `accept4` loop.
#
# We probe in two passes:
#   1. `pkg-config --exists liburing` lets us pick up Debian/Ubuntu's
#      pkg-config metadata and add the right -L/-l flags. Quiet failure
#      is fine — the second pass catches header-only setups (vendored
#      installs, distros without pkg-config metadata).
#   2. `have_header('liburing.h')` + `have_library('uring', ...)` covers
#      the no-pkg-config path.
#
# On success: `-DHAVE_LIBURING` lands in $defs (mkmf-managed) and
# `io_uring_loop.c` compiles its real loop. On failure: the file
# compiles to a thin stub that returns `:unavailable`.
#
# Linux-only — the loop is `#ifdef __linux__` guarded too, so a
# liburing-on-FreeBSD setup (technically possible) still picks the
# stub. Worth-it cost: portability + zero surprise on the bench host.
RbConfig::CONFIG['target_os'] =~ /linux/ && begin
  pkg_ok = system('pkg-config --exists liburing 2>/dev/null')
  if pkg_ok
    $CFLAGS << ' ' + `pkg-config --cflags liburing`.strip
    $LDFLAGS << ' ' + `pkg-config --libs liburing`.strip
    have_header('liburing.h')
    $defs << '-DHAVE_LIBURING'
    puts '[hyperion] liburing detected via pkg-config — building 2.12-D io_uring accept loop'
  elsif have_header('liburing.h') && have_library('uring', 'io_uring_queue_init')
    $defs << '-DHAVE_LIBURING'
    puts '[hyperion] liburing detected via header probe — building 2.12-D io_uring accept loop'
  else
    puts '[hyperion] liburing not found — 2.12-D io_uring accept loop will return :unavailable; ' \
         'install `liburing-dev` (Debian/Ubuntu) / `liburing-devel` (Fedora) for the io_uring path'
  end
end

create_makefile('hyperion_http/hyperion_http')
