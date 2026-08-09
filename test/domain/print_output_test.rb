require_relative '../test_helper'
require_relative '../../lib/domain/print_output'

# Tests for Domain::PrintOutput - where a print job actually wrote its PDF
class PrintOutputTest < Minitest::Test
  def test_returns_the_local_path_behind_a_file_uri
    assert_equal '/home/me/notes.pdf',
                 Domain::PrintOutput.pdf_path('file:///home/me/notes.pdf')
  end

  def test_decodes_percent_escapes_in_the_path
    assert_equal '/home/me/my notes.pdf',
                 Domain::PrintOutput.pdf_path('file:///home/me/my%20notes.pdf')
  end

  def test_decodes_a_non_ascii_path
    assert_equal '/home/me/résumé.pdf',
                 Domain::PrintOutput.pdf_path('file:///home/me/r%C3%A9sum%C3%A9.pdf')
  end

  def test_ignores_output_that_is_not_a_pdf
    assert_nil Domain::PrintOutput.pdf_path('file:///home/me/notes.ps')
  end

  def test_ignores_a_missing_output_uri
    assert_nil Domain::PrintOutput.pdf_path(nil)
  end

  def test_ignores_an_empty_output_uri
    assert_nil Domain::PrintOutput.pdf_path('')
  end

  def test_the_extension_check_is_case_sensitive_like_the_print_dialog
    assert_nil Domain::PrintOutput.pdf_path('file:///home/me/notes.PDF')
  end

  # Known wart, preserved: the URI is decoded as a form component rather than
  # as a path, so a literal '+' in a filename comes back as a space and the
  # bookmark pass looks for a file that is not there.
  def test_wart_a_plus_in_the_filename_is_decoded_as_a_space
    assert_equal '/home/me/a b.pdf', Domain::PrintOutput.pdf_path('file:///home/me/a+b.pdf')
  end
end
