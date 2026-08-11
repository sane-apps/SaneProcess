#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'stringio'
require 'tmpdir'
require 'uri'

require_relative '../hooks/test/test_framework'
require_relative 'cws_oauth_authorize'

include TestFramework

class OAuthRecordingSocket
  attr_reader :writes

  def initialize(&on_first_write)
    @writes = []
    @on_first_write = on_first_write
  end

  def write(value)
    @on_first_write&.call if @writes.empty?
    @writes << value
    value.bytesize
  end
end

exit(run_tests('CWS OAuth Authorize Tests') do
  test('authorization URL is desktop loopback PKCE and exact read-only scope') do
    url = SaneCwsOauthAuthorize.authorization_url(
      client_id: 'client-fixture',
      redirect_uri: 'http://127.0.0.1:43123/oauth/callback',
      state: 'state-fixture',
      challenge: 'challenge-fixture'
    )
    uri = URI(url)
    params = URI.decode_www_form(uri.query).to_h

    assert_eq(uri.host, 'accounts.google.com')
    assert_eq(params['scope'], SaneCwsOauthAuthorize::SCOPE)
    assert_eq(params['redirect_uri'], 'http://127.0.0.1:43123/oauth/callback')
    assert_eq(params['code_challenge_method'], 'S256')
    assert_eq(params['access_type'], 'offline')
    assert_eq(params['prompt'], 'consent')
    true
  end

  test('callback requires exact path state and authorization code') do
    line = 'GET /oauth/callback?state=expected&code=code-fixture HTTP/1.1'
    code = SaneCwsOauthAuthorize.parse_callback(line, expected_state: 'expected')
    assert_eq(code, 'code-fixture')

    begin
      SaneCwsOauthAuthorize.parse_callback(line, expected_state: 'wrong')
      assert(false, 'state mismatch must fail')
    rescue SaneAppReviewWatch::WatchError => e
      assert_includes(e.message, 'state mismatch')
    end
    true
  end

  test('desktop PKCE token exchange omits an unavailable client secret') do
    configuration = {
      'SANE_CWS_CLIENT_ID' => 'client-fixture'
    }
    requester = lambda do |fields|
      assert_eq(fields[:code_verifier], 'verifier-fixture')
      assert(!fields.key?(:client_secret), 'desktop PKCE exchange sent an empty client secret')
      assert_eq(fields.keys.sort, %i[client_id code code_verifier grant_type redirect_uri].sort)
      {
        code: 200,
        body: JSON.generate(
          refresh_token: 'refresh-fixture',
          access_token: 'access-fixture',
          scope: SaneCwsOauthAuthorize::SCOPE,
          token_type: 'Bearer'
        )
      }
    end
    refresh = SaneCwsOauthAuthorize.exchange_code(
      code: 'code-fixture', verifier: 'verifier-fixture',
      redirect_uri: 'http://127.0.0.1:43123/oauth/callback',
      configuration: configuration, requester: requester
    )
    assert_eq(refresh, 'refresh-fixture')
    true
  end

  test('token exchange preserves optional client-secret compatibility') do
    configuration = {
      'SANE_CWS_CLIENT_ID' => 'client-fixture',
      'SANE_CWS_CLIENT_SECRET' => 'secret-fixture'
    }
    requester = lambda do |fields|
      assert_eq(fields[:client_secret], 'secret-fixture')
      {
        code: 200,
        body: JSON.generate(
          refresh_token: 'refresh-fixture',
          scope: SaneCwsOauthAuthorize::SCOPE
        )
      }
    end
    refresh = SaneCwsOauthAuthorize.exchange_code(
      code: 'code-fixture', verifier: 'verifier-fixture',
      redirect_uri: 'http://127.0.0.1:43123/oauth/callback',
      configuration: configuration, requester: requester
    )
    assert_eq(refresh, 'refresh-fixture')
    true
  end

  test('token exchange fails closed before a request when client id is missing') do
    requested = false
    begin
      SaneCwsOauthAuthorize.exchange_code(
        code: 'code-fixture', verifier: 'verifier-fixture',
        redirect_uri: 'http://127.0.0.1:43123/oauth/callback',
        configuration: {}, requester: ->(_fields) { requested = true }
      )
      assert(false, 'missing client id must fail')
    rescue SaneAppReviewWatch::WatchError => e
      assert_includes(e.message, 'missing SANE_CWS_CLIENT_ID')
      assert(!requested, 'token endpoint was called without a client id')
    end
    true
  end

  test('token exchange rejects broadened or absent scopes without leaking tokens') do
    configuration = {
      'SANE_CWS_CLIENT_ID' => 'client-fixture',
      'SANE_CWS_CLIENT_SECRET' => 'secret-fixture'
    }
    requester = lambda do |_fields|
      {
        code: 200,
        body: JSON.generate(
          refresh_token: 'must-not-leak',
          scope: "#{SaneCwsOauthAuthorize::SCOPE} https://www.googleapis.com/auth/chromewebstore"
        )
      }
    end
    begin
      SaneCwsOauthAuthorize.exchange_code(
        code: 'code', verifier: 'verifier', redirect_uri: 'http://127.0.0.1:1/oauth/callback',
        configuration: configuration, requester: requester
      )
      assert(false, 'broadened scope must fail')
    rescue SaneAppReviewWatch::WatchError => e
      assert_includes(e.message, 'unexpected scope')
      assert(!e.message.include?('must-not-leak'))
    end
    true
  end

  test('private authorization URL file is mode 600 and rejects symlinks') do
    Dir.mktmpdir('cws-oauth-url') do |dir|
      path = File.join(dir, 'url')
      SaneCwsOauthAuthorize.write_private_url(path, 'https://example.invalid')
      assert_eq(File.stat(path).mode & 0o777, 0o600)

      File.delete(path)
      File.symlink(File.join(dir, 'elsewhere'), path)
      begin
        SaneCwsOauthAuthorize.write_private_url(path, 'https://example.invalid')
        assert(false, 'symlink must fail')
      rescue SaneAppReviewWatch::WatchError => e
        assert_includes(e.message, 'must not be a symlink')
      end
    end
    true
  end

  test('success response is emitted only after exchange and private storage complete') do
    order = []
    socket = OAuthRecordingSocket.new { order << :response }
    exchanger = lambda do |**_args|
      order << :exchange
      'refresh-fixture'
    end
    storer = lambda do |value|
      order << :store
      assert_eq(value, 'refresh-fixture')
      { 'value' => 'redacted' }
    end
    result = SaneCwsOauthAuthorize.complete_authorization(
      socket: socket,
      code: 'code-fixture',
      verifier: 'verifier-fixture',
      redirect_uri: 'http://127.0.0.1:43123/oauth/callback',
      configuration: {},
      exchanger: exchanger,
      storer: storer
    )

    assert_eq(order.first(3), %i[exchange store response])
    assert_eq(result['value'], 'redacted')
    assert_includes(socket.writes.join, '200 OK')

    failed_socket = OAuthRecordingSocket.new
    begin
      SaneCwsOauthAuthorize.complete_authorization(
        socket: failed_socket,
        code: 'code-fixture',
        verifier: 'verifier-fixture',
        redirect_uri: 'http://127.0.0.1:43123/oauth/callback',
        configuration: {},
        exchanger: exchanger,
        storer: ->(_value) { raise SaneAppReviewWatch::WatchError, 'store failed' }
      )
      assert(false, 'failed storage must not produce a success response')
    rescue SaneAppReviewWatch::WatchError
      assert_eq(failed_socket.writes, [])
    end
    true
  end

  test('callback reader accepts a complete request and bounds stalled or oversized clients') do
    reader, writer = Socket.pair(:UNIX, :STREAM, 0)
    writer.write("GET /oauth/callback?state=s&code=c HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
    line = SaneCwsOauthAuthorize.read_callback_request_line(reader, timeout_seconds: 0.2)
    assert_eq(line, 'GET /oauth/callback?state=s&code=c HTTP/1.1' + "\r\n")
    reader.close
    writer.close

    stalled_reader, stalled_writer = Socket.pair(:UNIX, :STREAM, 0)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    begin
      SaneCwsOauthAuthorize.read_callback_request_line(stalled_reader, timeout_seconds: 0.01)
      assert(false, 'stalled callback client must time out')
    rescue SaneAppReviewWatch::WatchError => e
      assert_includes(e.message, 'timed out')
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      assert(elapsed < 0.5, "callback timeout was not bounded: #{elapsed}")
    ensure
      stalled_reader.close
      stalled_writer.close
    end

    large_reader, large_writer = Socket.pair(:UNIX, :STREAM, 0)
    large_writer.write("GET /oauth/callback HTTP/1.1\r\nX-Fill: #{'a' * 64}")
    begin
      SaneCwsOauthAuthorize.read_callback_request_line(
        large_reader, timeout_seconds: 0.2, max_header_bytes: 64
      )
      assert(false, 'oversized callback headers must fail')
    rescue SaneAppReviewWatch::WatchError => e
      assert_includes(e.message, 'too large')
    ensure
      large_reader.close
      large_writer.close
    end
    true
  end
end)
