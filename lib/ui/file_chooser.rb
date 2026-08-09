require 'gtk3'

# A modal file chooser, built from filter descriptors.
#
# Three places asked the user for a file -- Ctrl+O, the PDF bookmark chooser,
# and an `<input type="file">` on a page -- with the same forty lines of dialog
# construction between them. What actually differed is the title, which filters
# to offer, whether more than one file may be picked and whether images get a
# preview, so those are the constructor arguments.
#
# A filter is a `Domain::FileFilters::Filter` descriptor, or a ready-made
# `Gtk::FileFilter` (WebKit hands one over for a page's `accept` attribute).
class FileChooser
  PREVIEW_SIZE = 200

  # @param parent [Gtk::Window] Window the dialog is modal to
  # @param title [String] Dialog title
  # @param filters [Array<Domain::FileFilters::Filter, Gtk::FileFilter>] Offered filters
  # @param select_multiple [Boolean] Whether more than one file may be chosen
  # @param preview [Boolean] Whether to show an image preview of the highlighted file
  def initialize(parent:, title:, filters: [], select_multiple: false, preview: false)
    @parent = parent
    @title = title
    @filters = filters.compact
    @select_multiple = select_multiple
    @preview = preview
  end

  # Shows the dialog and waits for the user
  #
  # @return [Array<String>] Chosen paths; empty if the user cancelled
  def choose
    dialog = build_dialog
    chosen = dialog.run == :accept ? Array(dialog.filenames).compact : []
    dialog.destroy
    chosen
  end

  # Builds the dialog without showing it
  #
  # Public so a test can inspect what was built -- running it needs a user.
  #
  # @return [Gtk::FileChooserDialog]
  def build_dialog
    dialog = Gtk::FileChooserDialog.new(
      title: @title,
      parent: @parent,
      action: :open,
      buttons: [['Cancel', :cancel], ['Open', :accept]]
    )

    dialog.select_multiple = @select_multiple
    @filters.each { |filter| dialog.add_filter(self.class.gtk_filter(filter)) }
    attach_preview(dialog) if @preview

    dialog
  end

  # Turns a filter descriptor into the GTK filter that implements it
  #
  # @param filter [Domain::FileFilters::Filter, Gtk::FileFilter] Descriptor or filter
  # @return [Gtk::FileFilter]
  def self.gtk_filter(filter)
    return filter if filter.is_a?(Gtk::FileFilter)

    gtk = Gtk::FileFilter.new
    gtk.name = filter.name
    filter.mime_types.each { |mime_type| gtk.add_mime_type(mime_type) }
    filter.patterns.each { |pattern| gtk.add_pattern(pattern) }
    gtk
  end

  # Draws a file into the preview widget
  #
  # @param image [Gtk::Image] The preview widget
  # @param filename [String, nil] File the chooser is highlighting
  # @return [Boolean] Whether an image was drawn (false leaves the preview hidden)
  def self.load_preview(image, filename)
    unless filename && File.exist?(filename)
      image.clear
      return false
    end

    pixbuf = GdkPixbuf::Pixbuf.new(file: filename, width: PREVIEW_SIZE, height: PREVIEW_SIZE)
    image.pixbuf = pixbuf
    true
  rescue StandardError => e
    # Not an image, or one GdkPixbuf cannot read -- an ordinary outcome here
    warn "Preview unavailable for #{filename}: #{e.class} - #{e.message}"
    image.clear
    false
  end

  private

  # @param dialog [Gtk::FileChooserDialog] Dialog to add the preview widget to
  # @return [void]
  def attach_preview(dialog)
    image = Gtk::Image.new
    image.set_size_request(PREVIEW_SIZE, PREVIEW_SIZE)
    dialog.preview_widget = image
    dialog.use_preview_label = false

    dialog.signal_connect('update-preview') do
      dialog.preview_widget_active = self.class.load_preview(image, dialog.preview_filename)
    end
  end
end
