# frozen_string_literal: true

require 'mkmf'

# llhttp source files vendored under ext/hyperion_http/llhttp/.
# We compile them in-tree (single static unit) rather than linking a
# system library, so the gem builds standalone on any host with a C
# compiler + Ruby headers.
$srcs = %w[
  parser.c
  llhttp.c
  api.c
  http.c
]
$VPATH << '$(srcdir)/llhttp'
$INCFLAGS << ' -I$(srcdir)/llhttp'
$CFLAGS << ' -O2 -fno-strict-aliasing'

create_makefile('hyperion_http/hyperion_http')
