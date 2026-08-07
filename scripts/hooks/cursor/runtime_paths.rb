#!/usr/bin/env ruby
# frozen_string_literal: true

# Resolves repository-owned hook implementations after the small Cursor
# adapters are copied into ~/.cursor/hooks. The installer records the actual
# checkout path, so public clones do not depend on ~/SaneApps.

module SaneCursorRuntimePaths
  module_function

  ROOT_POINTER = File.expand_path('~/.cursor/saneprocess_root').freeze

  def root
    candidates = []
    candidates << ENV['SANEPROCESS_DIR'].to_s
    candidates << File.read(ROOT_POINTER).strip if File.file?(ROOT_POINTER)
    candidates << File.expand_path('../../..', __dir__)
    candidates << File.expand_path('~/SaneApps/infra/SaneProcess')

    candidates.map(&:strip).reject(&:empty?).uniq.find do |candidate|
      File.directory?(File.join(candidate, 'scripts', 'hooks'))
    end
  rescue SystemCallError
    nil
  end

  def hook(relative_path)
    base = root
    base ? File.join(base, 'scripts', 'hooks', relative_path) : nil
  end
end
