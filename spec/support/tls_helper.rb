# frozen_string_literal: true

require 'openssl'

module TLSHelper
  module_function

  # Self-signed cert + key for tests only. Cached per-process.
  def self_signed
    @self_signed ||= begin
      key = OpenSSL::PKey::RSA.new(2048)
      cert = OpenSSL::X509::Certificate.new
      cert.version = 2
      cert.serial = 1
      cert.subject = OpenSSL::X509::Name.parse('/CN=localhost')
      cert.issuer = cert.subject
      cert.public_key = key.public_key
      cert.not_before = Time.now
      cert.not_after = Time.now + 3600
      cert.sign(key, OpenSSL::Digest.new('SHA256'))
      [cert, key]
    end
  end
end
