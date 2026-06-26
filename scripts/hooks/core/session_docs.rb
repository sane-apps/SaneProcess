# frozen_string_literal: true

module SaneSessionDocs
  module_function

  def project_dir
    value = ENV['CLAUDE_PROJECT_DIR'].to_s
    value.empty? ? Dir.pwd : value
  end

  def expected_paths_for(doc_name, session_docs)
    required_paths = session_docs[:required_paths] || session_docs['required_paths'] || {}
    configured = required_paths[doc_name] || required_paths[doc_name.to_sym]
    candidates = Array(configured)
    candidates << default_doc_path(doc_name) if candidates.empty?
    candidates.map { |path| File.expand_path(path.to_s) }
  end

  def read_matches?(file_path, doc_name, session_docs)
    actual = File.expand_path(file_path.to_s)
    return true if expected_paths_for(doc_name, session_docs).include?(actual)

    # Basename fallback for docs NOT explicitly pinned via :required_paths.
    # The default expected path is File.join(project_dir, doc), but project_dir
    # (CLAUDE_PROJECT_DIR || Dir.pwd) drifts from the project whose StateManager
    # holds the gate, and some required docs (e.g. SKILLS_REGISTRY.md) live
    # outside the project dir entirely — both make the exact-path gate
    # unsatisfiable. Matching by basename when unpinned lets a genuine read of
    # the doc at any resolvable location count, while pinned docs still require
    # their exact configured path.
    return false if explicitly_pinned?(doc_name, session_docs)

    File.basename(actual) == File.basename(doc_name.to_s)
  rescue StandardError
    false
  end

  def explicitly_pinned?(doc_name, session_docs)
    required_paths = session_docs[:required_paths] || session_docs['required_paths'] || {}
    !(required_paths[doc_name] || required_paths[doc_name.to_sym]).nil?
  end

  def default_doc_path(doc_name)
    doc = doc_name.to_s
    doc.start_with?('/') ? doc : File.join(project_dir, doc)
  end
end
