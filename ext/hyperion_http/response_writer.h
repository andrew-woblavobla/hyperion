/* response_writer.h — internal header shared between parser.c and
 * response_writer.c. NOT installed; only seen by ext sources.
 *
 * Exposes the head-builder symbols that response_writer.c needs to
 * reuse `c_build_response_head`-equivalent logic without going back
 * through Ruby method dispatch on the hot path. */

#ifndef HYPERION_RESPONSE_WRITER_H
#define HYPERION_RESPONSE_WRITER_H

#include <ruby.h>

/* Build an HTTP/1.1 response-head string into a fresh Ruby String.
 * Same behavior as the Ruby-visible
 * `Hyperion::CParser.build_response_head(...)` (parser.c). */
VALUE hyperion_build_response_head(VALUE status, VALUE reason, VALUE headers,
                                   VALUE body_size, VALUE keep_alive,
                                   VALUE date_str);

/* Build a chunked-encoding response-head string. Same byte shape as
 * the Ruby-visible `build_head_chunked` in response_writer.rb but
 * native, allocating one Ruby String. Implemented as
 * cbuild_response_head with body_size = -1 sentinel. */
VALUE hyperion_build_response_head_chunked(VALUE status, VALUE reason,
                                           VALUE headers, VALUE keep_alive,
                                           VALUE date_str);

#endif /* HYPERION_RESPONSE_WRITER_H */
