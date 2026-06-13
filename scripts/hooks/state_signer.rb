#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# State File Signer (VULN-003 FIX)
# ==============================================================================
# Provides HMAC-based signatures for state files to prevent tampering.
# Claude cannot bypass enforcement by editing state files directly because
# the signature would be invalid without knowing the secret.
#
# Usage:
#   require_relative 'state_signer'
#   StateSigner.write_signed(path, data)
#   data = StateSigner.read_verified(path)  # Returns nil if tampered
#
# Secret key sources (in order of preference):
#   1. CLAUDE_HOOK_SECRET environment variable
#   2. Existing macOS Keychain item (service: claude_hook, account: hmac_secret)
#   3. File-based (~/.claude_hook_secret, mode 600)
#   4. Auto-generated file fallback
#
# Keychain writes are opt-in via SANE_HOOK_KEYCHAIN_WRITE=1. Hook/test runs must
# not trigger GUI "store password" prompts while trying to self-heal state.
# ==============================================================================

require 'json'
require 'openssl'
require 'fileutils'
require 'securerandom'
require 'shellwords'
require 'open3'
require 'time'

module StateSigner
  SECRET_ENV_VAR = 'CLAUDE_HOOK_SECRET'
  KEYCHAIN_SERVICE = 'claude_hook'
  KEYCHAIN_ACCOUNT = 'hmac_secret'
  SECRET_FILE = File.expand_path('~/.claude_hook_secret')  # Legacy fallback
  ENV_CACHE_FILE = File.expand_path(ENV.fetch('SANE_ENV_CACHE_FILE', '~/.config/nv/env'))
  SIGNATURE_KEY = '__sig__'
  TIMESTAMP_KEY = '__ts__'

  class << self
    def secret
      @secret ||= load_or_generate_secret
    end

    def sign(data)
      payload = data.to_json
      OpenSSL::HMAC.hexdigest('SHA256', secret, payload)
    end

    def verify(data, signature)
      expected = sign(data)
      secure_compare(expected, signature)
    end

    # Write data with embedded signature
    def write_signed(path, data)
      data = data.dup
      data[TIMESTAMP_KEY] = Time.now.utc.iso8601

      # Remove existing signature before computing new one
      data.delete(SIGNATURE_KEY)
      data[SIGNATURE_KEY] = sign(data)

      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate(data))
      data
    end

    # Read and verify signed data
    # Returns nil if file doesn't exist, signature invalid, or tampered
    def read_verified(path, symbolize: false)
      return nil unless File.exist?(path)

      # Explicit UTF-8: hook subprocesses may run without a UTF-8 locale, and a
      # US-ASCII default external encoding makes JSON.parse raise on any
      # non-ASCII byte (e.g. an em-dash in a recorded block reason). That used
      # to read back as "tampered" and silently reset all enforcement state.
      raw = File.read(path, encoding: Encoding::UTF_8)
      data = JSON.parse(raw)  # String keys for signature verification

      signature = data.delete(SIGNATURE_KEY)
      return nil unless signature

      return nil unless verify(data, signature)

      # Optionally symbolize keys after verification
      symbolize ? JSON.parse(raw, symbolize_names: true).tap { |h| h.delete(:__sig__) } : data
    rescue JSON::ParserError, StandardError
      nil
    end

    # Read without verification (for migration/debugging)
    def read_unverified(path)
      return nil unless File.exist?(path)

      JSON.parse(File.read(path, encoding: Encoding::UTF_8))
    rescue JSON::ParserError, StandardError
      nil
    end

    # Check if a file has a valid signature
    def valid?(path)
      !read_verified(path).nil?
    end

    # Migrate an existing unsigned file to signed format
    def migrate_to_signed(path)
      return false unless File.exist?(path)

      data = JSON.parse(File.read(path, encoding: Encoding::UTF_8))
      data.delete(SIGNATURE_KEY) # Remove any existing signature
      write_signed(path, data)
      true
    rescue JSON::ParserError, StandardError
      false
    end

    private

    def macos?
      RUBY_PLATFORM.include?('darwin')
    end

    def load_env_cache
      return unless File.exist?(ENV_CACHE_FILE)

      File.foreach(ENV_CACHE_FILE) do |raw_line|
        line = raw_line.strip
        next if line.empty? || line.start_with?('#')

        line = line.delete_prefix('export ').strip
        next unless line.include?('=')

        key, raw_value = line.split('=', 2)
        next if key.nil? || key.empty? || ENV.key?(key)

        value = Shellwords.split(raw_value.to_s).first || raw_value.to_s.strip
        value = File.expand_path(value) if key.end_with?('_PATH') && value.start_with?('~')
        ENV[key] = value
      end
    rescue StandardError
      nil
    end

    def persist_secret_to_env_cache(secret)
      return if secret.nil? || secret.empty?
      return if ENV.fetch('SANE_ENV_CACHE_WRITE', '0') == '0'

      env_dir = File.dirname(ENV_CACHE_FILE)
      FileUtils.mkdir_p(env_dir)
      File.chmod(0o700, env_dir) rescue nil

      lines = File.exist?(ENV_CACHE_FILE) ? File.readlines(ENV_CACHE_FILE, chomp: true) : []
      filtered = lines.reject { |line| line.strip.start_with?("export #{SECRET_ENV_VAR}=") }
      filtered << "export #{SECRET_ENV_VAR}=#{Shellwords.escape(secret)}"
      File.write(ENV_CACHE_FILE, filtered.join("\n") + "\n")
      File.chmod(0o600, ENV_CACHE_FILE)
      ENV[SECRET_ENV_VAR] = secret
    rescue StandardError
      nil
    end

    def load_or_generate_secret
      load_env_cache

      # Priority 1: Environment variable (all platforms)
      env_secret = ENV[SECRET_ENV_VAR]
      return env_secret if env_secret && !env_secret.empty?

      # Priority 2: macOS Keychain (not readable by Bash cat)
      if macos?
        keychain_secret = read_keychain
        return keychain_secret if keychain_secret
      end

      # Priority 3: File-based secret (primary on Linux, fallback on macOS)
      if File.exist?(SECRET_FILE)
        file_secret = File.read(SECRET_FILE).strip
        if file_secret && !file_secret.empty?
          if macos? && keychain_write_enabled?
            write_keychain(file_secret)
            File.delete(SECRET_FILE) rescue nil
          end
          return file_secret
        end
      end

      # Priority 4: Generate new secret
      new_secret = SecureRandom.hex(32)
      if macos? && keychain_write_enabled?
        write_keychain(new_secret)
      else
        write_secret_file(new_secret)
      end
      new_secret
    end

    def read_keychain
      return nil if ENV['SANE_NO_KEYCHAIN'] == '1'

      result, = Open3.capture2(
        'security', 'find-generic-password',
        '-s', KEYCHAIN_SERVICE,
        '-a', KEYCHAIN_ACCOUNT,
        '-w',
        err: File::NULL
      )
      result = result.to_s.strip
      persist_secret_to_env_cache(result) unless result.empty?
      result.empty? ? nil : result
    rescue StandardError
      nil
    end

    def write_keychain(secret)
      return write_secret_file(secret) unless keychain_write_enabled?

      # Delete existing entry if present (security add fails on duplicate)
      system(
        'security', 'delete-generic-password',
        '-s', KEYCHAIN_SERVICE,
        '-a', KEYCHAIN_ACCOUNT,
        out: File::NULL,
        err: File::NULL
      )
      success = system(
        'security', 'add-generic-password',
        '-s', KEYCHAIN_SERVICE,
        '-a', KEYCHAIN_ACCOUNT,
        '-w', secret,
        out: File::NULL,
        err: File::NULL
      )
      persist_secret_to_env_cache(secret) if success
      # Fall back to file if Keychain write fails
      write_secret_file(secret) unless success
    rescue StandardError
      write_secret_file(secret)
    end

    def keychain_write_enabled?
      ENV['SANE_HOOK_KEYCHAIN_WRITE'] == '1'
    end

    def write_secret_file(secret)
      File.write(SECRET_FILE, secret)
      File.chmod(0o600, SECRET_FILE)
    end

    # Constant-time comparison to prevent timing attacks
    def secure_compare(a, b)
      return false unless a.bytesize == b.bytesize

      l = a.unpack('C*')
      r = b.unpack('C*')
      result = 0
      l.zip(r) { |x, y| result |= x ^ y }
      result.zero?
    end
  end
end

# CLI mode for testing/migration
if __FILE__ == $PROGRAM_NAME
  require 'optparse'

  options = {}
  OptionParser.new do |opts|
    opts.banner = 'Usage: state_signer.rb [options] <file>'

    opts.on('-v', '--verify', 'Verify file signature') { options[:verify] = true }
    opts.on('-s', '--sign', 'Sign file (in place)') { options[:sign] = true }
    opts.on('-m', '--migrate', 'Migrate unsigned to signed') { options[:migrate] = true }
    opts.on('-r', '--read', 'Read verified content') { options[:read] = true }
  end.parse!

  file = ARGV[0]
  unless file
    warn 'Error: No file specified'
    exit 1
  end

  if options[:verify]
    if StateSigner.valid?(file)
      puts '✅ Signature valid'
      exit 0
    else
      puts '❌ Signature INVALID or missing'
      exit 1
    end
  elsif options[:sign] || options[:migrate]
    if StateSigner.migrate_to_signed(file)
      puts "✅ File signed: #{file}"
      exit 0
    else
      puts "❌ Failed to sign: #{file}"
      exit 1
    end
  elsif options[:read]
    data = StateSigner.read_verified(file)
    if data
      puts JSON.pretty_generate(data)
      exit 0
    else
      warn '❌ File invalid or tampered'
      exit 1
    end
  else
    warn 'Specify --verify, --sign, --migrate, or --read'
    exit 1
  end
end
