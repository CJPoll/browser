require 'minitest/autorun'
require_relative '../../lib/domain/external_schemes'

class ExternalSchemesTest < Minitest::Test
  def test_application_scheme_is_external
    assert Domain::ExternalSchemes.external?("spotify://track/4uLU6hMCjMI75M1A2tKUQC")
  end

  def test_warp_scheme_is_external
    assert Domain::ExternalSchemes.external?("warp://action/new_tab")
  end

  def test_scheme_matching_is_case_insensitive
    assert Domain::ExternalSchemes.external?("SPOTIFY://track/1")
  end

  def test_http_is_not_external
    refute Domain::ExternalSchemes.external?("http://example.com")
  end

  def test_https_is_not_external
    refute Domain::ExternalSchemes.external?("https://example.com")
  end

  def test_file_is_not_external
    refute Domain::ExternalSchemes.external?("file:///tmp/notes.md")
  end

  def test_unknown_scheme_is_not_external
    refute Domain::ExternalSchemes.external?("gopher://example.com")
  end

  # Known wart, preserved from the original implementation: schemes are detected
  # by splitting on "://", so the opaque schemes in the list (mailto, tel, sms)
  # are never recognised in practice.
  def test_mailto_is_not_detected_because_it_lacks_a_double_slash
    refute Domain::ExternalSchemes.external?("mailto:someone@example.com")
  end

  def test_text_without_a_scheme_separator_is_not_external
    refute Domain::ExternalSchemes.external?("spotify")
  end

  def test_empty_string_is_not_external
    refute Domain::ExternalSchemes.external?("")
  end

  def test_nil_is_not_external
    refute Domain::ExternalSchemes.external?(nil)
  end

  def test_scheme_must_be_at_the_start_of_the_url
    refute Domain::ExternalSchemes.external?("https://example.com/redirect?to=slack://open")
  end

  def test_every_listed_scheme_is_recognised
    Domain::ExternalSchemes::SCHEMES.each do |scheme|
      assert Domain::ExternalSchemes.external?("#{scheme}://target"),
             "expected #{scheme} to be recognised as external"
    end
  end

  def test_scheme_list_is_frozen
    assert Domain::ExternalSchemes::SCHEMES.frozen?
  end
end
