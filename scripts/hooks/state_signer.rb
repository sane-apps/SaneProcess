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
#   2. macOS Keychain (service: claude_hook, account: hmac_secret)
#   3. Auto-generated on first use (stored in keychain)
# ==============================================================================

require 'json'
require 'openssl'
require 'fileutils'
require 'securerandom'

module StateSigner
  SECRET_ENV_VAR = 'CLAUDE_HOOK_SECRET'
  KEYCHAIN_SERVICE = 'claude_hook'
  KEYCHAIN_ACCOUNT = 'hmac_secret'
  SECRET_FILE = File.expand_path('~/.claude_hook_secret')  # Legacy fallback
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

      raw = File.read(path)
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

      JSON.parse(File.read(path))
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

      data = JSON.parse(File.read(path))
      data.delete(SIGNATURE_KEY) # Remove any existing signature
      write_signed(path, data)
      true
    rescue JSON::ParserError, StandardError
      false
    end

    private

    def load_or_generate_secret
      # Priority 1: Environment variable
      env_secret = ENV[SECRET_ENV_VAR]
      return env_secret if env_secret && !env_secret.empty?

      # Priority 2: macOS Keychain (not readable by Bash cat)
      keychain_secret = read_keychain
      return keychain_secret if keychain_secret

      # Priority 3: Migrate from legacy file to keychain
      if File.exist?(SECRET_FILE)
        file_secret = File.read(SECRET_FILE).strip
        if file_secret && !file_secret.empty?
          write_keychain(file_secret)
          File.delete(SECRET_FILE) rescue nil
          return file_secret
        end
      end

      # Priority 4: Generate new secret and store in keychain
      new_secret = SecureRandom.hex(32)
      write_keychain(new_secret)
      new_secret
    end

    def read_keychain
      result = `security find-generic-password -s #{KEYCHAIN_SERVICE} -a #{KEYCHAIN_ACCOUNT} -w 2>/dev/null`.strip
      result.empty? ? nil : result
    rescue StandardError
      nil
    end

    def write_keychain(secret)
      # Delete existing entry if present (security add fails on duplicate)
      system("security delete-generic-password -s #{KEYCHAIN_SERVICE} -a #{KEYCHAIN_ACCOUNT} 2>/dev/null")
      system("security add-generic-password -s #{KEYCHAIN_SERVICE} -a #{KEYCHAIN_ACCOUNT} -w #{secret}")
    rescue StandardError
      # Fallback: write to file if keychain fails (e.g., Linux)
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
