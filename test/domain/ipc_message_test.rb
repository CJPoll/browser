require 'minitest/autorun'
require_relative '../../lib/domain/ipc_message'

class DomainIpcMessageTest < Minitest::Test
  TIMESTAMP = 1_700_000_000.5

  def build_message(**overrides)
    Domain::IpcMessage.new(**{ url: 'https://example.com', timestamp: TIMESTAMP }.merge(overrides))
  end

  # === Construction ===

  def test_requires_a_timestamp
    error = assert_raises(ArgumentError) { Domain::IpcMessage.new(url: 'https://example.com', timestamp: nil) }
    assert_equal 'timestamp is required', error.message
  end

  def test_treats_a_missing_url_as_empty
    assert_equal '', Domain::IpcMessage.new(url: nil, timestamp: TIMESTAMP).url
  end

  def test_defaults_to_reusing_the_existing_window
    refute build_message.new_window?
  end

  def test_coerces_new_window_to_a_boolean
    assert_equal true, build_message(new_window: 'true').new_window?
    assert_equal false, build_message(new_window: nil).new_window?
  end

  def test_is_frozen
    assert build_message.frozen?
  end

  # === url? ===

  def test_url_predicate_is_true_when_a_url_was_requested
    assert build_message(url: 'https://example.com').url?
  end

  def test_url_predicate_is_false_for_an_empty_url
    refute build_message(url: '').url?
  end

  # A blank --new-window request carries no URL at all.
  def test_url_predicate_is_false_for_a_missing_url
    refute build_message(url: nil).url?
  end

  # === Serialisation ===

  def test_serializes_url_timestamp_and_window_flag_on_three_lines
    message = build_message(url: 'https://example.com', new_window: true)

    assert_equal "https://example.com\n#{TIMESTAMP}\ntrue", message.serialize
  end

  def test_serializes_a_urlless_request_with_a_leading_blank_line
    message = build_message(url: '', new_window: true)

    assert_equal "\n#{TIMESTAMP}\ntrue", message.serialize
  end

  def test_round_trips_through_serialize_and_parse
    message = build_message(url: 'https://example.com/a?b=c', new_window: true)

    assert_equal message, Domain::IpcMessage.parse(message.serialize)
  end

  # === Parsing ===

  def test_parses_a_three_line_request
    message = Domain::IpcMessage.parse("https://example.com\n#{TIMESTAMP}\ntrue")

    assert_equal 'https://example.com', message.url
    assert_in_delta TIMESTAMP, message.timestamp, 0.0001
    assert message.new_window?
  end

  def test_parses_a_request_that_reuses_the_window
    assert_equal false, Domain::IpcMessage.parse("https://example.com\n#{TIMESTAMP}\nfalse").new_window?
  end

  def test_parses_a_urlless_new_window_request
    message = Domain::IpcMessage.parse("\n#{TIMESTAMP}\ntrue")

    refute message.url?
    assert message.new_window?
  end

  def test_parses_nil_content_as_no_message
    assert_nil Domain::IpcMessage.parse(nil)
  end

  # A half-written file is read as a stale message rather than raising; the
  # zero timestamp keeps it from ever looking fresher than the last one seen.
  def test_parses_empty_content_as_a_message_with_a_zero_timestamp
    message = Domain::IpcMessage.parse('')

    refute message.url?
    assert_equal 0.0, message.timestamp
    refute message.new_window?
  end

  def test_parses_a_truncated_request_without_raising
    message = Domain::IpcMessage.parse("https://example.com\n")

    assert_equal 'https://example.com', message.url
    assert_equal 0.0, message.timestamp
    refute message.new_window?
  end

  # === Freshness ===

  def test_is_newer_than_an_earlier_timestamp
    assert build_message(timestamp: 100.0).newer_than?(99.0)
  end

  def test_is_not_newer_than_its_own_timestamp
    refute build_message(timestamp: 100.0).newer_than?(100.0)
  end

  def test_is_not_newer_than_a_later_timestamp
    refute build_message(timestamp: 100.0).newer_than?(101.0)
  end

  # The primary instance starts with a zero watermark so that a request
  # written just before it launched is still picked up.
  def test_any_real_timestamp_is_newer_than_the_initial_watermark
    assert build_message(timestamp: TIMESTAMP).newer_than?(0.0)
  end

  # === Value semantics ===

  def test_messages_with_the_same_attributes_are_equal
    assert_equal build_message, build_message
  end

  def test_messages_differing_in_url_are_not_equal
    refute_equal build_message(url: 'https://a.example'), build_message(url: 'https://b.example')
  end

  def test_messages_differing_in_window_flag_are_not_equal
    refute_equal build_message(new_window: true), build_message(new_window: false)
  end

  def test_is_not_equal_to_a_lookalike_hash
    refute_equal build_message, { url: 'https://example.com', timestamp: TIMESTAMP, new_window: false }
  end
end
