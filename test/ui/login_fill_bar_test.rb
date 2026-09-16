# frozen_string_literal: true

require 'minitest/autorun'
require 'gtk3'
require_relative '../../lib/ui/login_fill_bar'
require_relative '../../lib/domain/login_fill_prompt'
require_relative '../../lib/domain/login_fill_notice'
require_relative '../../lib/domain/login_candidate'

class UiLoginFillBarTest < Minitest::Test
  FAKE_PASSWORD = 'correct-horse-battery-staple'

  def setup
    @filled = []
    @cancelled = 0
    @bar = LoginFillBar.new(on_fill: ->(index) { @filled << index }, on_cancel: -> { @cancelled += 1 })
  end

  def teardown
    @bar.widget.destroy unless @bar.widget.destroyed?
  end

  def candidate(title, username = nil)
    Domain::LoginCandidate.new(item_id: title, vault_id: 'v', title: title, username: username, urls: ['https://google.com'])
  end

  def prompt(candidates)
    Domain::LoginFillPrompt.new(origin: 'https://accounts.google.com', site_key: 'google.com', candidates: candidates)
  end

  def widgets_of(kind, widget = @bar.widget)
    found = widget.is_a?(kind) ? [widget] : []
    found + (widget.respond_to?(:children) ? widget.children.flat_map { |child| widgets_of(kind, child) } : [])
  end

  def label_texts = widgets_of(Gtk::Label).map(&:text)
  def button_labels = widgets_of(Gtk::Button).map(&:label)

  def test_single_prompt_renders_the_message_and_fill_cancel
    single = prompt([candidate('GitHub', 'cody@example.com')])
    @bar.show_prompt(single)

    assert_includes label_texts, single.message
    assert_equal ['Fill', 'Cancel'], button_labels
    assert_empty widgets_of(Gtk::ComboBoxText)
  end

  def test_several_prompt_renders_a_chooser_with_every_label
    @bar.show_prompt(prompt([candidate('GitHub', 'cody@example.com'), candidate('Work', 'work@example.com')]))

    chooser = widgets_of(Gtk::ComboBoxText).first
    refute_nil chooser
    assert_equal 0, chooser.active
    assert_equal 'GitHub (cody@example.com)', chooser.active_text
  end

  def test_user_data_is_rendered_literally
    @bar.show_prompt(prompt([candidate('<b>x</b> & co')]))

    assert(label_texts.any? { |text| text.include?('<b>x</b> & co') })
  end

  def test_notice_renders_message_and_only_dismiss
    notice = Domain::LoginFillNotice.new(reason: :no_login_form)
    @bar.show_notice(notice)

    assert_includes label_texts, notice.message
    assert_equal ['Dismiss'], button_labels
    assert_empty widgets_of(Gtk::ComboBoxText)
  end

  def test_fill_reports_the_chosen_index
    @bar.show_prompt(prompt([candidate('A'), candidate('B')]))
    widgets_of(Gtk::ComboBoxText).first.active = 1

    @bar.fill

    assert_equal [1], @filled
  end

  def test_fill_on_a_single_prompt_reports_zero
    @bar.show_prompt(prompt([candidate('A')]))

    @bar.fill

    assert_equal [0], @filled
  end

  def test_cancel_reports_and_destroys
    @bar.show_prompt(prompt([candidate('A')]))

    @bar.cancel

    assert_equal 1, @cancelled
    assert @bar.widget.destroyed?
  end

  def test_never_renders_a_password
    @bar.show_prompt(prompt([candidate('GitHub', 'cody@example.com')]))

    refute(label_texts.any? { |text| text.include?(FAKE_PASSWORD) })
  end

  def test_holds_no_manager_or_webview
    refute(@bar.instance_variables.any? { |name| name.to_s.match?(/manager|webview/) })
  end
end
