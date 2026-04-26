# frozen_string_literal: true

# Hyperion::CParser — C extension wrapping Node's llhttp.
# Implements the same interface as Hyperion::Parser:
#   parse(buffer) -> [Request, end_offset] | raise ParseError | raise UnsupportedError
#
# If the extension didn't compile (e.g. no C toolchain, JRuby), this require
# fails gracefully and Hyperion::Parser remains the only parser. Connection
# probes for `defined?(Hyperion::CParser)` to pick its default.
begin
  require 'hyperion_http/hyperion_http'
rescue LoadError => e
  Hyperion.logger.warn do
    {
      message: 'C parser not available — falling back to pure-Ruby parser',
      error: e.message
    }
  end
end
