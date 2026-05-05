# frozen_string_literal: true

require 'spec_helper'
require 'socket'

RSpec.describe 'ResponseWriter C-path fallback' do
  let(:writer) { Hyperion::ResponseWriter.new }
  let(:date_re) { /^date: [^\r]+\r\n/ }

  before { @r, @w = Socket.pair(:UNIX, :STREAM) }
  after  { [@r, @w].each { |s| s.close unless s.closed? } }

  context 'when c_writer_available? is forced false' do
    before { Hyperion::Http::ResponseWriter.c_writer_available = false }
    after  { Hyperion::Http::ResponseWriter.c_writer_available = nil }

    it 'falls back to the Ruby buffered writer' do
      expect(Hyperion::Http::ResponseWriter).not_to receive(:c_write_buffered)
      writer.write(@w, 200, { 'content-type' => 'text/plain' }, ['ok'],
                   keep_alive: true)
      @w.close
      expect(@r.read).to include("HTTP/1.1 200 OK\r\n")
    end

    it 'falls back for the chunked path too' do
      expect(Hyperion::Http::ResponseWriter).not_to receive(:c_write_chunked)
      writer.write(@w, 200, { 'transfer-encoding' => 'chunked' },
                   ['hello'], keep_alive: true)
      @w.close
      bytes = @r.read
      expect(bytes).to include("transfer-encoding: chunked\r\n")
      expect(bytes).to end_with("0\r\n\r\n")
    end

    it 'produces wire bytes byte-for-byte identical to the C path (modulo Date)' do
      headers = { 'content-type' => 'application/json' }
      body    = ['{"ok":true}']

      # Capture Ruby-path bytes.
      writer.write(@w, 200, headers, body, keep_alive: true)
      @w.close
      ruby_bytes = @r.read.gsub(date_re, '')

      # Restore C path and capture C-path bytes for comparison.
      Hyperion::Http::ResponseWriter.c_writer_available = nil
      cr, cw = Socket.pair(:UNIX, :STREAM)
      writer.write(cw, 200, headers, body, keep_alive: true)
      cw.close
      c_bytes = cr.read.gsub(date_re, '')
      cr.close

      expect(c_bytes).to eq(ruby_bytes)
    end
  end

  context 'when io is an SSLSocket-shape (real_fd_io? false)' do
    let(:fake_ssl) do
      ssl = double('SSLSocket')
      allow(ssl).to receive(:fileno).and_return(@w.fileno)
      written = []
      allow(ssl).to receive(:write) { |s| written << s; s.bytesize }
      allow(ssl).to receive(:is_a?).and_return(false)
      allow(ssl).to receive(:is_a?).with(StringIO).and_return(false)
      if defined?(::OpenSSL::SSL::SSLSocket)
        allow(ssl).to receive(:is_a?).with(::OpenSSL::SSL::SSLSocket).and_return(true)
      end
      ssl.instance_variable_set(:@written, written)
      ssl
    end

    it 'falls back to the Ruby path even when the C ext is loaded' do
      skip 'OpenSSL::SSL::SSLSocket not available' unless defined?(::OpenSSL::SSL::SSLSocket)
      expect(Hyperion::Http::ResponseWriter).not_to receive(:c_write_buffered)
      writer.write(fake_ssl, 200, { 'content-type' => 'text/plain' }, ['ok'],
                   keep_alive: true)
      written = fake_ssl.instance_variable_get(:@written).join
      expect(written).to include("HTTP/1.1 200 OK\r\n")
    end
  end

  context 'when the C module is undefined (build skew / cargo missing)' do
    it 'c_path_eligible? returns false' do
      hide_const('Hyperion::Http::ResponseWriter')
      expect(writer.send(:c_path_eligible?, @w)).to eq(false)
    end
  end

  context 'when c_writer_available? is true' do
    it 'c_path_eligible? returns true for a UNIX-socket fd' do
      expect(writer.send(:c_path_eligible?, @w)).to eq(true)
    end

    it 'c_path_eligible? returns false for a StringIO' do
      io = StringIO.new
      expect(writer.send(:c_path_eligible?, io)).to eq(false)
    end
  end
end
