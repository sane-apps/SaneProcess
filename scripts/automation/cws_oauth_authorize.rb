#!/usr/bin/env ruby
# frozen_string_literal: true

require 'base64'
require 'digest'
require 'fileutils'
require 'json'
require 'net/http'
require 'securerandom'
require 'socket'
require 'stringio'
require 'uri'

require_relative 'cws_review_watch'

module SaneCwsOauthAuthorize
  AUTH_URI = URI('https://accounts.google.com/o/oauth2/v2/auth')
  TOKEN_URI = URI('https://oauth2.googleapis.com/token')
  SCOPE = 'https://www.googleapis.com/auth/chromewebstore.readonly'
  CALLBACK_PATH = '/oauth/callback'
  DEFAULT_URL_PATH = File.expand_path('~/Library/Caches/SaneProcess/cws-oauth-url')
  WAIT_SECONDS = 300
  CALLBACK_READ_SECONDS = 5
  MAX_CALLBACK_HEADER_BYTES = 16_384

  module_function

  def pkce_pair(random: SecureRandom)
    verifier = random.urlsafe_base64(64, false)
    challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
    [verifier, challenge]
  end

  def authorization_url(client_id:, redirect_uri:, state:, challenge:)
    query = URI.encode_www_form(
      client_id: client_id,
      redirect_uri: redirect_uri,
      response_type: 'code',
      scope: SCOPE,
      access_type: 'offline',
      prompt: 'consent',
      include_granted_scopes: 'false',
      state: state,
      code_challenge: challenge,
      code_challenge_method: 'S256'
    )
    uri = AUTH_URI.dup
    uri.query = query
    uri.to_s
  end

  def parse_callback(request_line, expected_state:)
    method, target, protocol = request_line.to_s.strip.split(' ', 3)
    raise SaneAppReviewWatch::WatchError, 'CWS OAuth callback method is invalid' unless method == 'GET'
    raise SaneAppReviewWatch::WatchError, 'CWS OAuth callback protocol is invalid' unless protocol&.start_with?('HTTP/')

    uri = URI(target.to_s)
    raise SaneAppReviewWatch::WatchError, 'CWS OAuth callback path is invalid' unless uri.path == CALLBACK_PATH

    params = URI.decode_www_form(uri.query.to_s).to_h
    unless secure_compare(params['state'].to_s, expected_state.to_s)
      raise SaneAppReviewWatch::WatchError, 'CWS OAuth callback state mismatch'
    end
    if params['error']
      raise SaneAppReviewWatch::WatchError, "CWS OAuth authorization declined: #{params['error']}"
    end
    code = params['code'].to_s
    raise SaneAppReviewWatch::WatchError, 'CWS OAuth callback has no code' if code.empty?

    code
  rescue URI::InvalidURIError, ArgumentError
    raise SaneAppReviewWatch::WatchError, 'CWS OAuth callback is malformed'
  end

  def secure_compare(left, right)
    return false if left.empty? || left.bytesize != right.bytesize

    result = 0
    left.bytes.zip(right.bytes) { |a, b| result |= a ^ b }
    result.zero?
  end

  def write_private_url(path, value)
    expanded = File.expand_path(path)
    raise SaneAppReviewWatch::WatchError, 'CWS OAuth URL path must not be a symlink' if File.symlink?(expanded)

    directory = File.dirname(expanded)
    FileUtils.mkdir_p(directory, mode: 0o700)
    File.chmod(0o700, directory)
    temporary = File.join(directory, ".#{File.basename(expanded)}.#{Process.pid}")
    File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      file.write(value)
      file.flush
      file.fsync
    end
    File.chmod(0o600, temporary)
    File.rename(temporary, expanded)
    expanded
  ensure
    File.delete(temporary) if defined?(temporary) && temporary && File.exist?(temporary)
  end

  def exchange_code(code:, verifier:, redirect_uri:, configuration:, requester: nil)
    requester ||= method(:perform_token_request)
    response = requester.call(
      client_id: configuration.fetch('SANE_CWS_CLIENT_ID'),
      client_secret: configuration.fetch('SANE_CWS_CLIENT_SECRET'),
      code: code,
      code_verifier: verifier,
      grant_type: 'authorization_code',
      redirect_uri: redirect_uri
    )
    code_value = response.fetch(:code).to_i
    payload = JSON.parse(response.fetch(:body).to_s)
    unless (200..299).cover?(code_value)
      oauth_error = payload['error'].to_s
      suffix = oauth_error.empty? ? '' : " (#{oauth_error})"
      raise SaneAppReviewWatch::WatchError, "CWS OAuth token exchange returned HTTP #{code_value}#{suffix}"
    end

    refresh_token = payload['refresh_token'].to_s
    granted_scopes = payload['scope'].to_s.split
    raise SaneAppReviewWatch::WatchError, 'CWS OAuth token exchange returned no refresh token' if refresh_token.empty?
    unless granted_scopes == [SCOPE]
      raise SaneAppReviewWatch::WatchError, 'CWS OAuth token exchange returned an unexpected scope set'
    end
    refresh_token
  rescue JSON::ParserError, KeyError
    raise SaneAppReviewWatch::WatchError, 'CWS OAuth token exchange returned an invalid response'
  end

  def perform_token_request(fields)
    request = Net::HTTP::Post.new(TOKEN_URI)
    request['Content-Type'] = 'application/x-www-form-urlencoded'
    request.body = URI.encode_www_form(fields)
    response = Net::HTTP.start(
      TOKEN_URI.host, TOKEN_URI.port, use_ssl: true,
      open_timeout: 15, read_timeout: 30
    ) { |http| http.request(request) }
    { code: response.code.to_i, body: response.body.to_s }
  rescue SocketError, SystemCallError, Timeout::Error => e
    raise SaneAppReviewWatch::WatchError, "CWS OAuth token exchange failed: #{e.class}"
  end

  def respond(socket, success:)
    title = success ? 'Authorization received' : 'Authorization failed'
    body = success ? 'SaneProcess received the authorization. You may close this tab.' :
      'SaneProcess could not validate the authorization. Return to Codex for the error.'
    html = "<!doctype html><meta charset=\"utf-8\"><title>#{title}</title><h1>#{title}</h1><p>#{body}</p>"
    socket.write("HTTP/1.1 #{success ? '200 OK' : '400 Bad Request'}\r\n")
    socket.write("Content-Type: text/html; charset=utf-8\r\n")
    socket.write("Content-Length: #{html.bytesize}\r\nConnection: close\r\n\r\n#{html}")
  rescue SystemCallError
    nil
  end

  def read_callback_request_line(socket, timeout_seconds: CALLBACK_READ_SECONDS,
                                 max_header_bytes: MAX_CALLBACK_HEADER_BYTES,
                                 clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
    deadline = clock.call + timeout_seconds
    buffer = +''
    loop do
      remaining = deadline - clock.call
      raise SaneAppReviewWatch::WatchError, 'CWS OAuth callback read timed out' unless remaining.positive?

      ready = IO.select([socket], nil, nil, remaining)
      raise SaneAppReviewWatch::WatchError, 'CWS OAuth callback read timed out' unless ready

      chunk = socket.read_nonblock(4096, exception: false)
      raise SaneAppReviewWatch::WatchError, 'CWS OAuth callback closed before headers completed' if chunk.nil?
      next if chunk == :wait_readable

      buffer << chunk
      if buffer.bytesize > max_header_bytes
        raise SaneAppReviewWatch::WatchError, 'CWS OAuth callback headers are too large'
      end
      break if buffer.include?("\r\n\r\n") || buffer.include?("\n\n")
    end
    buffer.lines.first.to_s
  end

  def complete_authorization(socket:, code:, verifier:, redirect_uri:, configuration:,
                             exchanger: method(:exchange_code), storer: nil)
    refresh_token = exchanger.call(
      code: code,
      verifier: verifier,
      redirect_uri: redirect_uri,
      configuration: configuration
    )
    result = if storer
               storer.call(refresh_token)
             else
               SaneCwsReviewWatch.store_env_value_from_stdin(
                 'SANE_CWS_REFRESH_TOKEN', input: StringIO.new(refresh_token)
               )
             end
    respond(socket, success: true)
    result
  end

  def run(url_path: DEFAULT_URL_PATH, wait_seconds: WAIT_SECONDS)
    raise SaneAppReviewWatch::WatchError, 'CWS OAuth authorization is Mini-only' unless SaneCwsReviewWatch.mini_host?

    configuration = SaneCwsReviewWatch.credential_configuration
    %w[SANE_CWS_CLIENT_ID SANE_CWS_CLIENT_SECRET].each do |name|
      raise SaneAppReviewWatch::WatchError, "CWS OAuth credential is unavailable (missing #{name})" if configuration[name].to_s.empty?
    end
    server = TCPServer.new('127.0.0.1', 0)
    port = server.addr[1]
    redirect_uri = "http://127.0.0.1:#{port}#{CALLBACK_PATH}"
    state = SecureRandom.urlsafe_base64(32, false)
    verifier, challenge = pkce_pair
    url = authorization_url(
      client_id: configuration.fetch('SANE_CWS_CLIENT_ID'),
      redirect_uri: redirect_uri,
      state: state,
      challenge: challenge
    )
    stored_url_path = write_private_url(url_path, url)
    puts JSON.generate(status: 'authorization_required', browser: 'Brave', scope: SCOPE, url: 'stored_private')
    $stdout.flush

    ready = IO.select([server], nil, nil, wait_seconds)
    raise SaneAppReviewWatch::WatchError, 'CWS OAuth authorization timed out' unless ready

    socket = server.accept
    request_line = read_callback_request_line(socket)
    code = parse_callback(request_line, expected_state: state)
    result = complete_authorization(
      socket: socket,
      code: code,
      verifier: verifier,
      redirect_uri: redirect_uri,
      configuration: configuration
    )
    puts JSON.generate(status: 'authorized', scope: SCOPE, refresh_token: result.fetch('value'))
    0
  rescue SaneAppReviewWatch::WatchError => e
    respond(socket, success: false) if defined?(socket) && socket
    warn "cws_oauth_authorize: #{e.message}"
    2
  ensure
    socket&.close
    server&.close
    File.delete(stored_url_path) if defined?(stored_url_path) && stored_url_path && File.exist?(stored_url_path)
  end
end

exit(SaneCwsOauthAuthorize.run) if __FILE__ == $PROGRAM_NAME
