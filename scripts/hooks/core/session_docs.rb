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
    expected_paths_for(doc_name, session_docs).include?(actual)
  rescue StandardError
    false
  end

  def default_doc_path(doc_name)
    doc = doc_name.to_s
    doc.start_with?('/') ? doc : File.join(project_dir, doc)
  end
end
