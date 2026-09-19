# frozen_string_literal: true

# Logos Personal Book anti-patterns (owner 2026-09-10):
# Word footnotes never compile in Logos PBB; "Scripture connection" caption dumps
# pollute the reading text. Block at Write/Edit when touching build_book.py.

module SanePBBGuard
  module_function

  BUILD_BOOK = %r{(?:^|/)books/[^/]+/build_book\.py\z}.freeze
  BANNED = [
    [/FootnoteStore/, 'FootnoteStore — Logos PBB ignores Word footnotes; use Headword TN marks'],
    [/from\s+pipeline\.footnotes|import\s+pipeline\.footnotes/, 'pipeline.footnotes is legacy — do not import in build_book.py'],
    [/["']Scripture connection["']/, 'Do not emit "Scripture connection" captions — inline Bible links; Cf. / Possible allusion only for leftovers']
  ].freeze

  def violation_for(path, content)
    return nil if path.to_s.strip.empty? || content.nil?
    return nil unless BUILD_BOOK.match?(path.to_s.tr('\\', '/'))

    text = content.to_s
    BANNED.each do |pattern, reason|
      return reason if text.match?(pattern)
    end
    nil
  end
end
