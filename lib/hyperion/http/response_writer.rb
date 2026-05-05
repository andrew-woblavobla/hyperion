# frozen_string_literal: true

module Hyperion
  module Http
    # Direct-syscall response writer for plain-TCP kernel fds.
    #
    # The C primitives are registered as singleton methods on this
    # very module by `ext/hyperion_http/response_writer.c` (see
    # `Init_hyperion_response_writer`). Surface from C:
    #
    #   ResponseWriter.available?            -> true | false
    #   ResponseWriter.c_write_buffered(io, status, headers, body,
    #                                   keep_alive, date_str) -> Integer
    #   ResponseWriter.c_write_chunked(io, status, headers, body,
    #                                  keep_alive, date_str)  -> Integer
    #
    # Operators can flip the dispatcher off at runtime with
    # `Hyperion::Http::ResponseWriter.c_writer_available = false`
    # (test seam / A/B rollback). Mirrors the
    # `Hyperion::ResponseWriter.page_cache_available = false`
    # pattern (response_writer.rb:60-65).
    module ResponseWriter
      class << self
        attr_writer :c_writer_available

        def c_writer_available?
          return @c_writer_available unless @c_writer_available.nil?

          @c_writer_available =
            respond_to?(:available?) && available? &&
            respond_to?(:c_write_buffered) &&
            respond_to?(:c_write_chunked)
        end
      end
    end
  end
end
