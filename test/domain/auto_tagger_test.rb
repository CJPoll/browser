require 'minitest/autorun'
require_relative '../../lib/domain/auto_tagger'

class DomainAutoTaggerTest < Minitest::Test
  YOUTUBE_URL = 'https://www.youtube.com/watch?v=abc123'

  def build_tagger
    tagger = Domain::AutoTagger.new
    tagger.add(tag_name: 'ASMR', patterns: ['asmr'], fields: [:title, :channel], site: 'youtube.com')
    tagger.add(tag_name: 'Linux', patterns: ['linux', 'gentoo'], fields: :title)
    tagger
  end

  # --- matching ------------------------------------------------------------

  def test_matches_a_pattern_in_the_title
    assert_equal ['Linux'], build_tagger.tags_for(title: 'Why Gentoo?', url: 'https://example.com')
  end

  def test_matching_ignores_case_on_both_sides
    tags = build_tagger.tags_for(title: 'ASMR for LINUX users', url: YOUTUBE_URL)

    assert_equal ['ASMR', 'Linux'], tags
  end

  def test_matches_a_pattern_in_any_configured_field
    tags = build_tagger.tags_for(title: 'Rain sounds', channel: 'Gentle ASMR', url: YOUTUBE_URL)

    assert_equal ['ASMR'], tags
  end

  def test_ignores_fields_the_rule_does_not_name
    tags = build_tagger.tags_for(title: 'Rain sounds', channel: 'Linux Weekly', url: YOUTUBE_URL)

    assert_empty tags
  end

  def test_ignores_missing_and_blank_fields
    assert_empty build_tagger.tags_for(title: nil, channel: '   ', url: YOUTUBE_URL)
  end

  def test_returns_each_tag_once_even_if_two_rules_assign_it
    tagger = Domain::AutoTagger.new
    tagger.add(tag_name: 'Gaming', patterns: ['gaming'], fields: :title)
    tagger.add(tag_name: 'Gaming', patterns: ['gameplay'], fields: :title)

    assert_equal ['Gaming'], tagger.tags_for(title: 'Gaming gameplay', url: 'https://example.com')
  end

  def test_no_rules_means_no_tags
    assert_empty Domain::AutoTagger.new.tags_for(title: 'Anything', url: 'https://example.com')
  end

  # --- site restriction ----------------------------------------------------

  def test_a_site_restricted_rule_ignores_other_sites
    assert_empty build_tagger.tags_for(title: 'ASMR rain', url: 'https://example.com/asmr')
  end

  def test_a_site_restriction_accepts_the_bare_www_and_mobile_hosts
    ['https://youtube.com/watch?v=1', 'https://www.youtube.com/watch?v=1',
     'https://m.youtube.com/watch?v=1'].each do |url|
      assert_equal ['ASMR'], build_tagger.tags_for(title: 'ASMR rain', url: url), url
    end
  end

  def test_a_site_restricted_rule_needs_a_usable_url
    assert_empty build_tagger.tags_for(title: 'ASMR rain', url: nil)
    assert_empty build_tagger.tags_for(title: 'ASMR rain', url: 'not a url')
  end

  def test_an_unrestricted_rule_applies_without_a_url
    assert_equal ['Linux'], build_tagger.tags_for(title: 'Linux tips', url: nil)
  end

  # --- from_rules ----------------------------------------------------------

  def test_builds_rules_from_string_keyed_data
    tagger = Domain::AutoTagger.from_rules(
      [{ 'tag_name' => 'ASMR', 'patterns' => ['asmr'], 'fields' => %w[title channel],
         'site' => 'youtube.com' }]
    )

    assert_equal 1, tagger.rule_count
    assert_equal ['ASMR'], tagger.tags_for(channel: 'Gentle ASMR', url: YOUTUBE_URL)
    assert_empty tagger.tags_for(channel: 'Gentle ASMR', url: 'https://example.com')
  end

  def test_builds_rules_from_symbol_keyed_data
    tagger = Domain::AutoTagger.from_rules([{ tag_name: 'Tech', patterns: ['aws'], fields: :title }])

    assert_equal ['Tech'], tagger.tags_for(title: 'AWS outage', url: 'https://example.com')
  end

  def test_a_rule_without_a_site_is_unrestricted
    tagger = Domain::AutoTagger.from_rules([{ 'tag_name' => 'Tech', 'patterns' => ['aws'], 'fields' => 'title' }])

    assert_equal ['Tech'], tagger.tags_for(title: 'AWS outage', url: 'https://anywhere.example')
  end

  def test_no_rule_data_builds_an_empty_tagger
    assert_equal 0, Domain::AutoTagger.from_rules([]).rule_count
  end

  def test_incomplete_rule_data_is_rejected_rather_than_silently_ignored
    assert_raises(KeyError) do
      Domain::AutoTagger.from_rules([{ 'tag_name' => 'Tech', 'patterns' => ['aws'] }])
    end
  end

  # --- clear ---------------------------------------------------------------

  def test_clear_removes_every_rule
    tagger = build_tagger
    tagger.clear

    assert_equal 0, tagger.rule_count
    assert_empty tagger.tags_for(title: 'Linux tips', url: YOUTUBE_URL)
  end
end
