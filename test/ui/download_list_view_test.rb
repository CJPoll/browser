require 'minitest/autorun'
require 'gtk3'
require_relative '../../lib/domain/download'
require_relative '../../lib/ui/download_list_view'

# The view is a UI Component: these tests only check that it renders the
# downloads it is handed and offers the controls the domain says it should.
#
# Note: GTK signal emission does not reach Ruby handlers under minitest in
# this environment, so button clicks cannot be simulated. The behaviour behind
# each button is covered by Domain::DownloadControls (which controls appear),
# DownloadCoordinator (what each intent does) and DownloadHandler (how it
# reaches WebKit).
class DownloadListViewTest < Minitest::Test
  CREATED_AT = Time.at(1_700_000_000).freeze

  def setup
    @downloads = []
    @view = DownloadListView.new(get_downloads: -> { @downloads })
  end

  def build_download(id: 1, state: :pending, **overrides)
    Download.new(**{
      id: id,
      url: 'https://example.com/file.pdf',
      destination: '/tmp/file.pdf',
      created_at: CREATED_AT,
      state: state
    }.merge(overrides))
  end

  def rows
    @view.list_widget.children
  end

  # Collects every button in a widget tree.
  def buttons_in(widget)
    return [widget] if widget.is_a?(Gtk::Button)
    return [] unless widget.respond_to?(:children)

    widget.children.flat_map { |child| buttons_in(child) }
  end

  def tooltips_for(download)
    @downloads = [download]
    @view.refresh
    rows.flat_map { |row| buttons_in(row) }.map(&:tooltip_text)
  end

  def test_empty_list_shows_a_placeholder
    @view.refresh

    assert_equal 1, rows.length
    labels = rows.first.children.select { |child| child.is_a?(Gtk::Label) }
    assert_equal ["No downloads"], labels.map(&:text)
  end

  def test_one_row_per_download
    @downloads = [build_download(id: 1), build_download(id: 2, state: :completed)]

    @view.refresh

    assert_equal 2, rows.length
  end

  def test_refresh_replaces_the_previous_rows
    @downloads = [build_download(id: 1), build_download(id: 2)]
    @view.refresh

    @downloads = [build_download(id: 1)]
    @view.refresh

    assert_equal 1, rows.length
  end

  def test_a_running_download_offers_pause_and_cancel
    assert_equal ["Pause", "Cancel"], tooltips_for(build_download(state: :in_progress))
  end

  def test_a_paused_download_offers_resume_and_cancel
    assert_equal ["Resume (re-downloads)", "Cancel"], tooltips_for(build_download(state: :paused))
  end

  def test_a_failed_download_offers_retry_and_remove
    download = build_download(state: :failed, error_message: 'boom')

    assert_equal ["Retry", "Remove"], tooltips_for(download)
  end

  def test_a_completed_download_offers_reveal_and_remove
    download = build_download(state: :completed)

    assert_equal ["Open File Location", "Remove"], tooltips_for(download)
  end

  def test_the_view_holds_no_manager
    refute @view.respond_to?(:download_manager),
           "UI Components must not expose a manager (ADR 001)"
  end

  def test_status_text_reports_each_state
    view = @view

    assert_equal 'Completed - 1.0 KB',
                 view.send(:status_text, build_download(state: :completed, total_bytes: 1024))
    assert_equal 'Failed: boom',
                 view.send(:status_text, build_download(state: :failed, error_message: 'boom'))
    assert_equal 'Cancelled',
                 view.send(:status_text, build_download(state: :cancelled))
    assert_equal 'Paused - 512 B / 1.0 KB',
                 view.send(:status_text, build_download(state: :paused, bytes_received: 512, total_bytes: 1024))
    assert_equal '512 B downloaded',
                 view.send(:status_text, build_download(state: :in_progress, bytes_received: 512))
  end
end
