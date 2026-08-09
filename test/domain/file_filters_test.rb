require_relative '../test_helper'
require_relative '../../lib/domain/file_filters'

# Tests for Domain::FileFilters - which file types each chooser offers
class FileFiltersTest < Minitest::Test
  # ============================================================
  # open_file
  # ============================================================

  def test_open_file_offers_all_files_first_so_it_is_the_default
    assert_equal 'All Files', Domain::FileFilters.open_file.first.name
  end

  def test_open_file_offers_the_types_the_browser_can_display
    names = Domain::FileFilters.open_file.map(&:name)

    assert_equal ['All Files', 'HTML Files', 'Markdown Files', 'PDF Files', 'Images'], names
  end

  def test_open_file_matches_both_markdown_extensions
    markdown = filter_named(Domain::FileFilters.open_file, 'Markdown Files')

    assert_equal ['*.md', '*.markdown'], markdown.patterns
    assert_equal ['text/markdown'], markdown.mime_types
  end

  def test_open_file_matches_both_html_extensions
    html = filter_named(Domain::FileFilters.open_file, 'HTML Files')

    assert_equal ['*.html', '*.htm'], html.patterns
    assert_equal ['text/html'], html.mime_types
  end

  def test_open_file_offers_images_by_mime_type_alone
    images = filter_named(Domain::FileFilters.open_file, 'Images')

    assert_equal ['image/*'], images.mime_types
    assert_empty images.patterns
  end

  # ============================================================
  # pdf
  # ============================================================

  def test_pdf_offers_only_pdfs
    assert_equal ['PDF Files'], Domain::FileFilters.pdf.map(&:name)
  end

  def test_pdf_matches_by_mime_type_and_extension
    pdf = Domain::FileFilters.pdf.first

    assert_equal ['application/pdf'], pdf.mime_types
    assert_equal ['*.pdf'], pdf.patterns
  end

  # ============================================================
  # for_upload
  # ============================================================

  def test_upload_always_offers_all_files
    assert_equal ['All Files'], Domain::FileFilters.for_upload([]).map(&:name)
  end

  def test_upload_offers_images_when_the_page_asks_for_them
    assert_equal ['All Images', 'All Files'], Domain::FileFilters.for_upload(['image/png']).map(&:name)
  end

  def test_upload_offers_images_when_only_one_of_several_types_is_an_image
    names = Domain::FileFilters.for_upload(['application/pdf', 'image/gif']).map(&:name)

    assert_includes names, 'All Images'
  end

  def test_upload_does_not_offer_images_for_non_image_types
    refute_includes Domain::FileFilters.for_upload(['application/pdf']).map(&:name), 'All Images'
  end

  def test_upload_treats_a_missing_type_list_as_no_types
    assert_equal ['All Files'], Domain::FileFilters.for_upload(nil).map(&:name)
  end

  # WebKit's own filter matches by MIME type, which misses files the desktop
  # sniffs differently (GIFs in particular), so the image filter spells the
  # extensions out as well.
  def test_upload_image_filter_lists_common_extensions_in_both_cases
    images = filter_named(Domain::FileFilters.for_upload(['image/*']), 'All Images')

    assert_includes images.patterns, '*.gif'
    assert_includes images.patterns, '*.GIF'
    assert_includes images.patterns, '*.jpeg'
    assert_includes images.patterns, '*.JPEG'
    assert_equal ['image/*'], images.mime_types
  end

  def test_upload_image_filter_covers_every_extension_the_browser_previews
    images = filter_named(Domain::FileFilters.for_upload(['image/*']), 'All Images')

    %w[gif png jpg jpeg webp bmp tiff svg ico].each do |extension|
      assert_includes images.patterns, "*.#{extension}"
    end
  end

  private

  def filter_named(filters, name)
    filters.find { |filter| filter.name == name }
  end
end
