#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../hooks/test/test_framework'

include TestFramework

exit(run_tests('SaneProcess Mini bootstrap credential tests') do
  test_category('Credential defaults') do
    test('does not synthesize SaneApps ASC credentials') do
      script = File.read(File.expand_path('bootstrap-build-server.sh', __dir__))

      assert(!script.include?('S34998ZCRT'), 'bootstrap should not hardcode the SaneApps key id')
      assert(!script.include?('c98b1e0a-8d10-4fce-a417-536b31c09bfb'), 'bootstrap should not hardcode the SaneApps issuer id')
      assert(!script.include?('AuthKey_S34998ZCRT.p8'), 'bootstrap should not hardcode the SaneApps key path')
      assert_includes(script, '<path-to-AuthKey.p8>')
      true
    end

    test('keeps ASC credentials on env or keychain path') do
      script = File.read(File.expand_path('bootstrap-build-server.sh', __dir__))

      assert_includes(script, 'env_file_get "${env_key}"')
      assert_includes(script, 'security find-generic-password -s "${service}" -w')
      assert_includes(script, 'resolve_secret "ASC_AUTH_KEY_ID" "saneprocess.asc.key_id"')
      assert_includes(script, 'resolve_secret "ASC_AUTH_ISSUER_ID" "saneprocess.asc.issuer_id"')
      assert_includes(script, 'resolve_secret "ASC_AUTH_KEY_PATH" "saneprocess.asc.key_path"')
      true
    end
  end
end)
