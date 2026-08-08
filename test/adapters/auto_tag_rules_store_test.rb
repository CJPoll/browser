require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'stringio'
require_relative '../../lib/adapters/auto_tag_rules_store'
require_relative '../../lib/domain/auto_tagger'

class AdaptersAutoTagRulesStoreTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('auto-tag-rules-test')
    @path = File.join(@dir, 'rules.json')
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && Dir.exist?(@dir)
  end

  def write(contents)
    File.write(@path, contents)
  end

  def store
    Adapters::AutoTagRulesStore.new(path: @path)
  end

  def test_loads_the_rules_from_the_documents_rules_key
    write({ rules: [{ tag_name: 'ASMR', patterns: ['asmr'], fields: ['title'] }] }.to_json)

    assert_equal [{ 'tag_name' => 'ASMR', 'patterns' => ['asmr'], 'fields' => ['title'] }], store.load
  end

  def test_loads_a_bare_array_of_rules
    write([{ tag_name: 'ASMR', patterns: ['asmr'], fields: ['title'] }].to_json)

    assert_equal 1, store.load.length
  end

  def test_a_missing_rules_file_means_no_rules
    assert_empty store.load
  end

  def test_a_malformed_rules_file_means_no_rules
    write('{ not json')

    assert_empty capture_warnings { store.load }
  end

  def test_a_document_without_rules_means_no_rules
    write({ note: 'nothing here yet' }.to_json)

    assert_empty store.load
  end

  # The shipped file is the one production loads, so it has to parse and build.
  def test_the_shipped_rules_file_builds_a_tagger
    rules = Adapters::AutoTagRulesStore.new.load
    refute_empty rules, 'the browser ships with auto-tag rules'

    tagger = Domain::AutoTagger.from_rules(rules)

    assert_equal rules.length, tagger.rule_count
    assert_includes tagger.tags_for(title: 'Silksong playthrough',
                                    url: 'https://www.youtube.com/watch?v=abc'), 'Silksong'
  end

  # Runs the block with stderr captured, returning the loaded rules.
  def capture_warnings
    original = $stderr
    $stderr = StringIO.new
    yield
  ensure
    $stderr = original
  end
end
