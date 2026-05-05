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

/* macOS lacks MSG_NOSIGNAL; fall back to 0 (no flag). Safe in a Ruby
 * process: MRI installs a custom SIGPIPE handler that converts the
 * signal into a soft event and the next IO call returns EPIPE — the
 * process is not killed. Our C sendmsg/writev calls run under the
 * GVL, so the same handler intercepts SIGPIPE for them. */
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
    rb_mHyperion = rb_const_get(rb_cObject, rb_intern("Hyperion"));
    /* Hyperion::Http may already exist (created by Init_hyperion_sendfile
     * earlier in Init_hyperion_http) or may not (init-order changes,
     * or a Ruby file opened the module first). Use the same guard
     * pattern as sendfile.c / page_cache.c so we never raise a
     * TypeError if a future caller defines Http as a class. */
    if (rb_const_defined(rb_mHyperion, rb_intern("Http"))) {
        rb_mHttp = rb_const_get(rb_mHyperion, rb_intern("Http"));
    } else {
        rb_mHttp = rb_define_module_under(rb_mHyperion, "Http");
    }
    rb_mResponseWriter = rb_define_module_under(rb_mHttp, "ResponseWriter");

    rb_define_singleton_method(rb_mResponseWriter, "available?",
                               c_response_writer_available_p, 0);
}
