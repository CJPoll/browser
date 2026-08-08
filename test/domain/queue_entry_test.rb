require 'minitest/autorun'
require_relative '../../lib/domain/queue_entry'

class DomainQueueEntryTest < Minitest::Test
  ADDED_AT = Time.at(1_700_000_000).freeze
  PUBLISHED_AT = Time.at(1_600_000_000).freeze

  def build_entry(**overrides)
    Domain::QueueEntry.new(**{
      url: 'https://example.com/article',
      added_at: ADDED_AT
    }.merge(overrides))
  end

  # === Construction ===

  def test_requires_a_url
    error = assert_raises(ArgumentError) do
      Domain::QueueEntry.new(url: nil, added_at: ADDED_AT)
    end
    assert_equal 'url is required', error.message
  end

  def test_rejects_an_empty_url
    assert_raises(ArgumentError) { Domain::QueueEntry.new(url: '', added_at: ADDED_AT) }
  end

  def test_requires_added_at
    error = assert_raises(ArgumentError) do
      Domain::QueueEntry.new(url: 'https://example.com', added_at: nil)
    end
    assert_equal 'added_at is required', error.message
  end

  # Regression guard: a defaulted `added_at:` would be a clock read in Domain
  def test_added_at_has_no_default
    assert_raises(ArgumentError) { Domain::QueueEntry.new(url: 'https://example.com') }
  end

  def test_optional_attributes_default_to_nil
    entry = build_entry

    assert_nil entry.id
    assert_nil entry.title
    assert_nil entry.favicon_data
    assert_nil entry.position
    assert_nil entry.published_at
  end

  def test_exposes_every_attribute
    entry = build_entry(
      id: 7,
      title: 'An article',
      favicon_data: 'PNGDATA',
      position: 3,
      published_at: PUBLISHED_AT
    )

    assert_equal 7, entry.id
    assert_equal 'https://example.com/article', entry.url
    assert_equal 'An article', entry.title
    assert_equal 'PNGDATA', entry.favicon_data
    assert_equal 3, entry.position
    assert_equal ADDED_AT, entry.added_at
    assert_equal PUBLISHED_AT, entry.published_at
  end

  def test_is_frozen
    assert build_entry.frozen?
  end

  # === queueable_url? ===

  def test_http_and_https_urls_are_queueable
    assert Domain::QueueEntry.queueable_url?('http://example.com')
    assert Domain::QueueEntry.queueable_url?('https://example.com/path?a=1')
  end

  def test_other_schemes_are_not_queueable
    refute Domain::QueueEntry.queueable_url?('file:///home/user/notes.md')
    refute Domain::QueueEntry.queueable_url?('mailto:someone@example.com')
    refute Domain::QueueEntry.queueable_url?('about:blank')
  end

  def test_a_url_without_a_scheme_is_not_queueable
    refute Domain::QueueEntry.queueable_url?('example.com')
  end

  def test_a_malformed_url_is_not_queueable
    refute Domain::QueueEntry.queueable_url?('http://[malformed')
  end

  def test_nil_is_not_queueable
    refute Domain::QueueEntry.queueable_url?(nil)
  end

  def test_an_empty_url_is_not_queueable
    refute Domain::QueueEntry.queueable_url?('')
  end

  # === display_title ===

  def test_display_title_is_the_title_when_present
    assert_equal 'An article', build_entry(title: 'An article').display_title
  end

  def test_display_title_falls_back_to_the_url
    assert_equal 'https://example.com/article', build_entry(title: nil).display_title
  end

  def test_display_title_falls_back_for_an_empty_title
    # Wart preserved: an empty-string title is truthy in Ruby, so it wins over
    # the URL. The metadata worker never writes one, but a page whose <title>
    # is blank would produce this.
    assert_equal '', build_entry(title: '').display_title
  end

  # === with ===

  def test_with_returns_a_copy_carrying_the_change
    original = build_entry
    updated = original.with(id: 42, position: 1)

    assert_equal 42, updated.id
    assert_equal 1, updated.position
    assert_equal original.url, updated.url
  end

  def test_with_does_not_mutate_the_original
    original = build_entry
    original.with(title: 'Renamed')

    assert_nil original.title
  end

  def test_with_can_clear_an_attribute
    assert_nil build_entry(title: 'An article').with(title: nil).title
  end

  # === Value semantics ===

  def test_entries_with_the_same_attributes_are_equal
    assert_equal build_entry(id: 1), build_entry(id: 1)
  end

  def test_entries_differing_in_any_attribute_are_not_equal
    refute_equal build_entry(id: 1), build_entry(id: 2)
    refute_equal build_entry, build_entry(url: 'https://example.com/other')
    refute_equal build_entry, build_entry(published_at: PUBLISHED_AT)
  end

  def test_is_not_equal_to_a_lookalike_hash
    refute_equal build_entry, build_entry.to_h
  end

  def test_can_be_used_as_a_hash_key
    counts = Hash.new(0)
    counts[build_entry(id: 1)] += 1
    counts[build_entry(id: 1)] += 1

    assert_equal({ build_entry(id: 1) => 2 }, counts)
  end
end
