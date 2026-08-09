require_relative '../test_helper'
require_relative '../../lib/ui/file_chooser'
require_relative '../../lib/domain/file_filters'

# Tests for FileChooser
#
# Running the dialog needs a user, so what is tested is what was built from the
# descriptors and the preview decision, both of which are reachable without one.
class FileChooserTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('file-chooser')
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
  end

  # ============================================================
  # gtk_filter
  # ============================================================

  def test_builds_a_gtk_filter_from_a_descriptor
    filter = FileChooser.gtk_filter(Domain::FileFilters::PDF_FILES)

    assert_kind_of Gtk::FileFilter, filter
    assert_equal 'PDF Files', filter.name
  end

  def test_passes_a_ready_made_gtk_filter_through_untouched
    existing = Gtk::FileFilter.new
    existing.name = 'From WebKit'

    assert_same existing, FileChooser.gtk_filter(existing)
  end

  # ============================================================
  # build_dialog
  # ============================================================

  def test_titles_the_dialog
    dialog = build_chooser(title: 'Select PDF to Add Bookmarks').build_dialog

    assert_equal 'Select PDF to Add Bookmarks', dialog.title
    dialog.destroy
  end

  def test_offers_every_filter_it_was_given
    dialog = build_chooser(filters: Domain::FileFilters.open_file).build_dialog

    assert_equal ['All Files', 'HTML Files', 'Markdown Files', 'PDF Files', 'Images'],
                 dialog.filters.map(&:name)
    dialog.destroy
  end

  def test_offers_a_gtk_filter_alongside_descriptors
    from_webkit = Gtk::FileFilter.new
    from_webkit.name = 'From WebKit'

    dialog = build_chooser(filters: [from_webkit, *Domain::FileFilters.for_upload(['image/png'])]).build_dialog

    assert_equal ['From WebKit', 'All Images', 'All Files'], dialog.filters.map(&:name)
    dialog.destroy
  end

  def test_ignores_a_filter_that_was_not_supplied
    dialog = build_chooser(filters: [nil, Domain::FileFilters::PDF_FILES]).build_dialog

    assert_equal ['PDF Files'], dialog.filters.map(&:name)
    dialog.destroy
  end

  def test_chooses_one_file_by_default
    dialog = build_chooser.build_dialog

    refute dialog.select_multiple?
    dialog.destroy
  end

  def test_chooses_several_files_when_the_page_allows_it
    dialog = build_chooser(select_multiple: true).build_dialog

    assert dialog.select_multiple?
    dialog.destroy
  end

  def test_has_no_preview_widget_unless_asked_for_one
    dialog = build_chooser.build_dialog

    assert_nil dialog.preview_widget
    dialog.destroy
  end

  def test_shows_a_preview_widget_when_asked
    dialog = build_chooser(preview: true).build_dialog

    assert_kind_of Gtk::Image, dialog.preview_widget
    dialog.destroy
  end

  # ============================================================
  # load_preview
  # ============================================================

  def test_previews_an_image
    path = write_png('picture.png')

    assert FileChooser.load_preview(Gtk::Image.new, path)
  end

  def test_scales_the_preview_down
    image = Gtk::Image.new
    FileChooser.load_preview(image, write_png('picture.png'))

    assert_operator image.pixbuf.width, :<=, FileChooser::PREVIEW_SIZE
    assert_operator image.pixbuf.height, :<=, FileChooser::PREVIEW_SIZE
  end

  def test_does_not_preview_a_file_that_is_not_an_image
    path = File.join(@dir, 'notes.txt')
    File.write(path, 'plain text')

    refute FileChooser.load_preview(Gtk::Image.new, path)
  end

  def test_does_not_preview_a_file_that_is_not_there
    refute FileChooser.load_preview(Gtk::Image.new, File.join(@dir, 'gone.png'))
  end

  def test_does_not_preview_when_nothing_is_highlighted
    refute FileChooser.load_preview(Gtk::Image.new, nil)
  end

  private

  def build_chooser(title: 'Open File', filters: [], select_multiple: false, preview: false)
    FileChooser.new(
      parent: nil,
      title: title,
      filters: filters,
      select_multiple: select_multiple,
      preview: preview
    )
  end

  def write_png(name)
    path = File.join(@dir, name)
    pixbuf = GdkPixbuf::Pixbuf.new(colorspace: :rgb, has_alpha: false, bits_per_sample: 8,
                                   width: 400, height: 400)
    pixbuf.fill!(0xff0000ff)
    pixbuf.save(path, 'png')
    path
  end
end
