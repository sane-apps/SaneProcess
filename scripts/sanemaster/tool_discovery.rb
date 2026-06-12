# frozen_string_literal: true

module SaneMasterModules
  module ToolDiscovery
    def tool_discovery(args = [])
      script = File.expand_path('../automation/tool_discovery_receipt.rb', __dir__)
      command = [RbConfig.ruby, script, '--project-root', Dir.pwd, *args]
      success = system({ 'SANEMASTER_TOOL_DISCOVERY' => '1' }, *command)
      return if success

      exit($CHILD_STATUS&.exitstatus || 1)
    end
  end
end
