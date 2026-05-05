/* response_writer.c — Hyperion::Http::ResponseWriter
 *
 * Direct-syscall response writer for plain-TCP kernel fds. Bypasses
 * Ruby IO machinery (encoding, fiber-yield checks, GVL release/
 * acquire) on the buffered hot path. TLS / non-fd / page-cache /
 * sendfile callers fall through to the Ruby ResponseWriter at the
 * dispatcher in response_writer.rb. */

#include <ruby.h>
#include <ruby/io.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <sys/socket.h>
#include <errno.h>
#include <unistd.h>
#include <string.h>

#include "response_writer.h"

#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0
#endif

static VALUE rb_mHyperion;
static VALUE rb_mHttp;
static VALUE rb_mResponseWriter;

static VALUE c_response_writer_available_p(VALUE self) {
    (void)self;
    return Qtrue;
}

void Init_hyperion_response_writer(void) {
    rb_mHyperion       = rb_const_get(rb_cObject, rb_intern("Hyperion"));
    /* Hyperion::Http may not be defined yet on first load (the Ruby
     * file lib/hyperion/http/response_writer.rb defines it). Use
     * `rb_define_module_under` which creates-or-fetches. */
    rb_mHttp           = rb_define_module_under(rb_mHyperion, "Http");
    rb_mResponseWriter = rb_define_module_under(rb_mHttp, "ResponseWriter");

    rb_define_singleton_method(rb_mResponseWriter, "available?",
                               c_response_writer_available_p, 0);
}
