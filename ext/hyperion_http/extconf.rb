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
  websocket.c
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

create_makefile('hyperion_http/hyperion_http')
