require 'minitest/autorun'
require 'gtk3'
require_relative '../../lib/ui/site_permissions_window'
require_relative '../../lib/domain/host_permission'

class SitePermissionsWindowTest < Minitest::Test
  GRANTED_AT = Time.at(1_700_000_000).freeze

  def setup
    @removed = []
    @permissions = [
      permission('apple.com'),
      permission('zebra.com')
    ]
  end

  def teardown
    @window&.destroy
  end

  def permission(host, permission_type: nil)
    Domain::HostPermission.new(
      host: host,
      permission_type: permission_type,
      granted_at: GRANTED_AT
    )
  end

  def build_section(**overrides)
    {
      title: "Popup Permissions",
      description: "Sites allowed to show popups:",
      empty_text: "No sites have popup permissions",
      get_permissions: -> { @permissions },
      on_remove: ->(perm) { @removed << perm }
    }.merge(overrides)
  end

  def build_window(sections)
    @window = SitePermissionsWindow.new(sections: sections)
  end

  # Walks the widget tree collecting every label's text.
  def label_texts(widget)
    return [widget.text] if widget.is_a?(Gtk::Label)
    return [] unless widget.respond_to?(:children)

    widget.children.flat_map { |child| label_texts(child) }
  end

  # --- Rendering ---

  def test_renders_the_section_heading_and_description
    build_window([build_section])

    texts = label_texts(@window)

    assert_includes texts, "Popup Permissions"
    assert_includes texts, "Sites allowed to show popups:"
  end

  def test_renders_one_row_per_permission
    build_window([build_section])

    texts = label_texts(@window)

    assert_includes texts, "apple.com"
    assert_includes texts, "zebra.com"
  end

  def test_renders_the_empty_text_when_a_section_has_no_permissions
    @permissions = []

    build_window([build_section])

    texts = label_texts(@window)

    assert_includes texts, "No sites have popup permissions"
  end

  def test_renders_every_section
    build_window([
      build_section,
      build_section(title: "Certificate Exceptions",
                    description: "Sites with trusted certificates:",
                    get_permissions: -> { [permission('localhost')] })
    ])

    texts = label_texts(@window)

    assert_includes texts, "Popup Permissions"
    assert_includes texts, "Certificate Exceptions"
    assert_includes texts, "localhost"
  end

  def test_renders_a_remove_button_for_each_permission
    build_window([build_section])

    assert_equal 2, count_remove_buttons(@window)
  end

  def test_renders_no_remove_button_for_an_empty_section
    @permissions = []

    build_window([build_section])

    assert_equal 0, count_remove_buttons(@window)
  end

  def count_remove_buttons(widget)
    return 1 if widget.is_a?(Gtk::Button) && widget.label == "Remove"
    return 0 unless widget.respond_to?(:children)

    widget.children.sum { |child| count_remove_buttons(child) }
  end

  # --- Row labels ---

  def test_a_row_is_labelled_with_the_host_by_default
    build_window([build_section(get_permissions: -> { [permission('example.com')] })])

    assert_includes label_texts(@window), "example.com"
  end

  def test_a_section_may_supply_its_own_row_label
    section = build_section(
      get_permissions: -> { [permission('meet.example.com', permission_type: :audio)] },
      row_label: ->(perm) { "#{perm.host} - #{perm.permission_type}" }
    )

    build_window([section])

    assert_includes label_texts(@window), "meet.example.com - audio"
  end

  # --- Remove intent ---

  def test_removing_a_permission_emits_the_sections_intent
    section = build_section
    build_window([section])

    @window.remove_permission(section, @permissions.first)

    assert_equal ['apple.com'], @removed.map(&:host)
  end

  def test_removing_a_permission_redraws_the_section_from_the_data_source
    section = build_section(on_remove: ->(perm) { @permissions.delete(perm) })
    build_window([section])

    @window.remove_permission(section, @permissions.first)

    texts = label_texts(@window)

    refute_includes texts, "apple.com"
    assert_includes texts, "zebra.com"
  end

  def test_removing_the_last_permission_shows_the_empty_text
    section = build_section(on_remove: ->(perm) { @permissions.delete(perm) })
    build_window([section])

    @permissions.dup.each { |perm| @window.remove_permission(section, perm) }

    assert_includes label_texts(@window), "No sites have popup permissions"
  end

  def test_removing_a_permission_leaves_other_sections_alone
    other = build_section(title: "Certificate Exceptions",
                          get_permissions: -> { [permission('localhost')] })
    section = build_section(on_remove: ->(perm) { @permissions.delete(perm) })
    build_window([section, other])

    @window.remove_permission(section, @permissions.first)

    assert_includes label_texts(@window), "localhost"
  end

  # A section without an intent still redraws rather than raising.
  def test_a_section_without_a_remove_intent_is_tolerated
    section = build_section(on_remove: nil)
    build_window([section])

    @window.remove_permission(section, @permissions.first)

    assert_includes label_texts(@window), "apple.com"
  end

  def test_a_section_without_a_data_source_renders_as_empty
    build_window([build_section(get_permissions: nil)])

    assert_includes label_texts(@window), "No sites have popup permissions"
  end

  # --- Refresh ---

  def test_refresh_redraws_every_section_from_its_data_source
    build_window([build_section])
    @permissions << permission('added-later.com')

    @window.refresh

    assert_includes label_texts(@window), "added-later.com"
  end

  # --- Bucket rules ---

  # ADR 001: a UI component may not hold a manager, repository or adapter.
  def test_holds_no_manager_or_repository
    build_window([build_section])

    collaborators = @window.instance_variables.map { |name| @window.instance_variable_get(name) }

    assert(collaborators.none? { |value| value.class.name.to_s =~ /Manager|Repository|Adapter/ })
  end
end
