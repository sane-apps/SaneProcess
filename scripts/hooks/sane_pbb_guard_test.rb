# frozen_string_literal: true

require 'minitest/autorun'
require_relative './sane_pbb_guard'

class SanePBBGuardTest < Minitest::Test
  def test_allows_clean_build_book
    assert_nil SanePBBGuard.violation_for(
      '/Users/sj/SaneApps/clients/translations/books/foo/build_book.py',
      "para('Cf.: Romans 5:12')\n"
    )
  end

  def test_blocks_footnote_store
    reason = SanePBBGuard.violation_for(
      'clients/translations/books/foo/build_book.py',
      "from pipeline.footnotes import FootnoteStore\n"
    )
    refute_nil reason
    assert_match(/FootnoteStore|footnotes/, reason)
  end

  def test_blocks_scripture_connection_label
    reason = SanePBBGuard.violation_for(
      'books/bar/build_book.py',
      'certainty = "Scripture connection"'
    )
    # path must be under books/*/build_book.py — relative books/bar works
    refute_nil reason
  end

  def test_ignores_non_build_book
    assert_nil SanePBBGuard.violation_for(
      'clients/translations/pipeline/footnotes.py',
      'class FootnoteStore'
    )
  end
end
