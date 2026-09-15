require_relative '../test_helper'
require_relative '../../lib/domain/crash_page'

# Tests for Domain::CrashPage - the page shown when a tab's web process dies
class CrashPageTest < Minitest::Test
  CRASHED_URL = 'https://www.youtube.com/watch?v=Ad9Q8rM0Am0'

  # ========================================
  # Normalizing WebKit's reason
  # ========================================

  def test_normalize_accepts_webkits_hyphenated_nicknames
    assert_equal :crashed, Domain::CrashPage.normalize('crashed')
    assert_equal :exceeded_memory_limit, Domain::CrashPage.normalize('exceeded-memory-limit')
    assert_equal :terminated_by_api, Domain::CrashPage.normalize('terminated-by-api')
  end

  def test_normalize_accepts_symbols_and_underscores
    assert_equal :exceeded_memory_limit, Domain::CrashPage.normalize(:exceeded_memory_limit)
    assert_equal :terminated_by_api, Domain::CrashPage.normalize('terminated_by_api')
  end

  def test_normalize_ignores_case_and_surrounding_whitespace
    assert_equal :crashed, Domain::CrashPage.normalize("  CRASHED\n")
  end

  # A WebKit version that grows a fourth reason must not raise inside a signal
  # handler, so an unknown reason is a value rather than an exception
  def test_normalize_maps_an_unrecognised_reason_to_unknown
    assert_equal :unknown, Domain::CrashPage.normalize('spontaneously-combusted')
  end

  def test_normalize_maps_nil_and_empty_to_unknown
    assert_equal :unknown, Domain::CrashPage.normalize(nil)
    assert_equal :unknown, Domain::CrashPage.normalize('')
  end

  # ========================================
  # Describing what happened
  # ========================================

  def test_describe_distinguishes_a_crash_from_the_memory_limit
    refute_equal Domain::CrashPage.describe('crashed'),
                 Domain::CrashPage.describe('exceeded-memory-limit')
  end

  def test_describe_names_memory_when_the_limit_was_exceeded
    assert_includes Domain::CrashPage.describe('exceeded-memory-limit'), 'memory'
  end

  def test_describe_falls_back_to_the_generic_sentence
    assert_equal Domain::CrashPage.describe('unknown'),
                 Domain::CrashPage.describe('something-new')
  end

  def test_every_reason_has_a_sentence
    Domain::CrashPage::REASONS.each_key do |reason|
      refute_empty Domain::CrashPage.describe(reason)
    end
  end

  # ========================================
  # The log line
  # ========================================

  def test_log_line_names_the_reason_and_the_url
    line = Domain::CrashPage.log_line(url: CRASHED_URL, reason: 'exceeded-memory-limit')

    assert_includes line, 'exceeded_memory_limit'
    assert_includes line, CRASHED_URL
  end

  def test_log_line_says_so_when_there_is_no_url
    assert_includes Domain::CrashPage.log_line(url: nil, reason: 'crashed'), '<no url>'
    assert_includes Domain::CrashPage.log_line(url: '', reason: 'crashed'), '<no url>'
  end

  def test_log_line_has_no_trailing_newline
    line = Domain::CrashPage.log_line(url: CRASHED_URL, reason: 'crashed')

    refute_match(/\n/, line)
  end

  # ========================================
  # The page
  # ========================================

  def test_html_is_a_complete_document
    html = Domain::CrashPage.html(url: CRASHED_URL, reason: 'crashed')

    assert_includes html, '<!DOCTYPE html>'
    assert_includes html, '</html>'
    assert_includes html, '<title>Page crashed</title>'
  end

  def test_html_says_what_happened
    html = Domain::CrashPage.html(url: CRASHED_URL, reason: 'exceeded-memory-limit')

    assert_includes html, Domain::CrashPage.describe('exceeded-memory-limit')
  end

  def test_html_offers_the_crashed_url_as_a_reload_link
    html = Domain::CrashPage.html(url: CRASHED_URL, reason: 'crashed')

    assert_includes html, %(href="#{CRASHED_URL}")
    assert_includes html, 'Reload page'
  end

  def test_html_carries_its_own_styles_so_the_page_needs_no_network
    html = Domain::CrashPage.html(url: CRASHED_URL, reason: 'crashed')

    assert_includes html, '<style>'
    refute_includes html, 'http://'
    refute_includes html, 'src='
  end

  def test_html_styles_for_dark_mode
    assert_includes Domain::CrashPage.html(url: CRASHED_URL, reason: 'crashed'),
                    'prefers-color-scheme: dark'
  end

  # A tab whose process died before it ever loaded anything has nothing to
  # link to, and must not offer an empty link
  def test_html_omits_the_reload_link_when_there_is_no_url
    [nil, '', '   '].each do |url|
      html = Domain::CrashPage.html(url: url, reason: 'crashed')

      refute_includes html, 'Reload page'
      refute_includes html, 'href='
      assert_includes html, Domain::CrashPage.describe('crashed')
    end
  end

  # The URL comes from the page that just died, so it is not to be trusted
  def test_html_escapes_the_url
    html = Domain::CrashPage.html(
      url: 'https://example.com/?q="><script>alert(1)</script>',
      reason: 'crashed'
    )

    refute_includes html, '<script>'
    assert_includes html, '&lt;script&gt;'
    assert_includes html, '&quot;&gt;'
  end

  def test_html_is_the_same_bytes_every_time
    assert_equal Domain::CrashPage.html(url: CRASHED_URL, reason: 'crashed'),
                 Domain::CrashPage.html(url: CRASHED_URL, reason: 'crashed')
  end
end
