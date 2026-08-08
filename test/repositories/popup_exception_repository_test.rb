require 'minitest/autorun'
require 'fileutils'
require_relative '../../lib/repositories/popup_exception_repository'

class PopupExceptionRepositoryTest < Minitest::Test
  GRANTED_AT = Time.at(1_700_000_000).freeze

  def setup
    @test_db_path = '/tmp/test_popup_exceptions.db'
    FileUtils.rm_f(@test_db_path)
    @repository = Repositories::PopupExceptionRepository.new(db_path: @test_db_path)
  end

  def teardown
    @repository&.close
    FileUtils.rm_f(@test_db_path)
  end

  def build_permission(host: 'example.com', granted_at: GRANTED_AT)
    Domain::HostPermission.new(host: host, granted_at: granted_at)
  end

  # --- add ---

  def test_add_returns_the_stored_permission_with_its_id
    stored = @repository.add(build_permission)

    refute_nil stored.id
    assert_equal 'example.com', stored.host
    assert_equal GRANTED_AT, stored.granted_at
  end

  def test_add_refuses_a_host_that_is_already_allowed
    @repository.add(build_permission)

    assert_nil @repository.add(build_permission)
    assert_equal 1, @repository.all.size
  end

  def test_add_keeps_distinct_hosts_separate
    @repository.add(build_permission(host: 'a.example.com'))
    @repository.add(build_permission(host: 'b.example.com'))

    assert_equal %w[a.example.com b.example.com], @repository.all.map(&:host)
  end

  # --- exists? ---

  def test_exists_is_false_before_the_host_is_added
    refute @repository.exists?('example.com')
  end

  def test_exists_is_true_after_the_host_is_added
    @repository.add(build_permission)

    assert @repository.exists?('example.com')
  end

  def test_exists_is_host_specific
    @repository.add(build_permission(host: 'example.com'))

    refute @repository.exists?('other.com')
  end

  def test_exists_is_false_for_a_missing_host
    refute @repository.exists?(nil)
  end

  # --- remove ---

  def test_remove_reports_the_deletion
    @repository.add(build_permission)

    assert @repository.remove('example.com')
    refute @repository.exists?('example.com')
  end

  def test_remove_reports_false_when_the_host_was_not_allowed
    refute @repository.remove('example.com')
  end

  def test_remove_reports_false_for_a_missing_host
    refute @repository.remove(nil)
  end

  # --- all ---

  def test_all_is_empty_initially
    assert_empty @repository.all
  end

  def test_all_returns_domain_objects_ordered_by_host
    @repository.add(build_permission(host: 'zebra.com'))
    @repository.add(build_permission(host: 'apple.com'))

    permissions = @repository.all

    assert(permissions.all? { |p| p.is_a?(Domain::HostPermission) })
    assert_equal %w[apple.com zebra.com], permissions.map(&:host)
  end

  def test_all_round_trips_the_grant_time
    @repository.add(build_permission(granted_at: Time.at(1_600_000_042)))

    assert_equal Time.at(1_600_000_042), @repository.all.first.granted_at
  end

  # --- persistence ---

  def test_records_survive_reconnection
    @repository.add(build_permission)
    @repository.close

    reopened = Repositories::PopupExceptionRepository.new(db_path: @test_db_path)
    begin
      assert reopened.exists?('example.com')
    ensure
      reopened.close
    end
  end

  # The on-disk schema is adopted as-is; renaming the table would orphan every
  # existing user's popups.db.
  def test_uses_the_existing_popup_exceptions_table
    @repository.add(build_permission)
    @repository.close

    db = SQLite3::Database.new(@test_db_path)
    begin
      assert_equal 1, db.get_first_value('SELECT COUNT(*) FROM popup_exceptions')
    ensure
      db.close
    end
  end
end
