require 'minitest/autorun'
require 'json'
require 'gtk3'
require_relative '../../lib/ui/passkey_prompt_bar'
require_relative '../../lib/domain/passkey_prompt'
require_relative '../../lib/domain/passkey_request'
require_relative '../../lib/domain/passkey'

class PasskeyPromptBarTest < Minitest::Test
  ORIGIN = 'https://accounts.example.com'.freeze
  NOW = Time.at(1_700_000_000).freeze

  def setup
    @allowed = []
    @cancelled = 0
    @bar = PasskeyPromptBar.new(on_allow: ->(choice) { @allowed << choice }, on_cancel: -> { @cancelled += 1 })
  end

  def teardown
    @bar.widget.destroy unless @bar.widget.destroyed?
  end

  def create_prompt(display_name: 'Cody')
    request = Domain::PasskeyRequest.parse(JSON.generate(
      'id' => 'passkey-1', 'op' => 'create',
      'options' => { 'challenge' => 'Y2hhbGxlbmdl', 'user' => { 'id' => 'dXNlcg', 'name' => 'cody@example.com', 'displayName' => display_name } }
    ))
    Domain::PasskeyPrompt.new(request: request, origin: ORIGIN, rp_id: 'accounts.example.com')
  end

  def get_prompt(*names)
    request = Domain::PasskeyRequest.parse(JSON.generate('id' => 'passkey-2', 'op' => 'get', 'options' => { 'challenge' => 'Y2hhbGxlbmdl' }))
    candidates = names.map do |name|
      Domain::Passkey.new(credential_id: "id-#{name}", rp_id: 'accounts.example.com', user_handle: 'dXNlcg',
                          user_name: name, private_key_pem: 'pem', created_at: NOW)
    end
    Domain::PasskeyPrompt.new(request: request, origin: ORIGIN, rp_id: 'accounts.example.com', candidates: candidates)
  end

  def widgets_of(kind, widget = @bar.widget)
    found = widget.is_a?(kind) ? [widget] : []
    found + (widget.respond_to?(:children) ? widget.children.flat_map { |child| widgets_of(kind, child) } : [])
  end

  def label_texts
    widgets_of(Gtk::Label).map(&:text)
  end

  def button_labels
    widgets_of(Gtk::Button).map(&:label)
  end

  # --- Rendering ---

  def test_shows_the_prompt_message
    @bar.show_prompt(create_prompt)

    assert_includes label_texts, 'accounts.example.com wants to create a passkey for Cody'
  end

  def test_renders_page_supplied_text_literally
    # The display name is the page's to choose; markup in it must not be interpreted.
    @bar.show_prompt(create_prompt(display_name: '<b>Cody</b> & co'))

    assert_includes label_texts, 'accounts.example.com wants to create a passkey for <b>Cody</b> & co'
  end

  def test_offers_to_create_a_passkey
    @bar.show_prompt(create_prompt)

    assert_equal ['Create passkey', 'Cancel'], button_labels
  end

  def test_offers_to_sign_in
    @bar.show_prompt(get_prompt('cody@example.com'))

    assert_equal ['Sign in', 'Cancel'], button_labels
  end

  def test_shows_no_chooser_when_there_is_nothing_to_choose
    @bar.show_prompt(get_prompt('cody@example.com'))

    assert_empty widgets_of(Gtk::ComboBoxText)
  end

  def test_shows_a_chooser_listing_every_passkey_when_there_are_several
    @bar.show_prompt(get_prompt('cody@example.com', 'work@example.com'))

    chooser = widgets_of(Gtk::ComboBoxText).first
    refute_nil chooser
    assert_equal 0, chooser.active
    assert_equal 'cody@example.com', chooser.active_text
  end

  # --- Intents ---

  def test_allow_reports_the_first_passkey_by_default
    @bar.show_prompt(get_prompt('cody@example.com', 'work@example.com'))

    @bar.allow

    assert_equal [0], @allowed
  end

  def test_allow_reports_the_chosen_passkey
    @bar.show_prompt(get_prompt('cody@example.com', 'work@example.com'))
    widgets_of(Gtk::ComboBoxText).first.active = 1

    @bar.allow

    assert_equal [1], @allowed
  end

  def test_allow_on_a_creation_prompt_reports_zero
    @bar.show_prompt(create_prompt)

    @bar.allow

    assert_equal [0], @allowed
  end

  def test_cancel_reports_the_refusal
    @bar.show_prompt(create_prompt)

    @bar.cancel

    assert_equal 1, @cancelled
    assert_empty @allowed
  end

  def test_answering_removes_the_bar
    @bar.show_prompt(create_prompt)

    @bar.allow

    assert @bar.widget.destroyed?
  end

  def test_holds_no_manager
    refute @bar.instance_variables.any? { |name| name.to_s.include?('manager') }
  end
end
