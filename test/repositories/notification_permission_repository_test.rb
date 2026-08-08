require 'minitest/autorun'
require 'fileutils'
require_relative '../../lib/repositories/notification_permission_repository'

class NotificationPermissionRepositoryTest < Minitest::Test
  GRANTED_AT = Time.at(1_700_000_000).freeze

  def setup
    @test_db_path = '/tmp/test_notification_permissions.db'
    FileUtils.rm_f(@test_db_path)
    @repository = Repositories::NotificationPermissionRepository.new(db_path: @test_db_path)
  end

  def teardown
    @repository&.close
    FileUtils.rm_f(@test_db_path)
  end

  def build_permission(host: 'claude.ai', granted_at: GRANTED_AT)
    Domain::HostPermission.new(host: host, granted_at: granted_at)
  end

  def test_add_returns_the_stored_permission_with_its_id
    stored = @repository.add(build_permission)

    refute_nil stored.id
    assert_equal 'claude.ai', stored.host
    assert_equal GRANTED_AT, stored.granted_at
  end

  def test_add_refuses_a_host_that_is_already_allowed
    @repository.add(build_permission)

    assert_nil @repository.add(build_permission)
    assert_equal 1, @repository.all.size
  end

  def test_exists_reflects_what_was_added
    refute @repository.exists?('claude.ai')

    @repository.add(build_permission)

    assert @repository.exists?('claude.ai')
    refute @repository.exists?('other.com')
  end

  def test_exists_is_false_for_a_missing_host
    refute @repository.exists?(nil)
  end

  def test_remove_reports_the_deletion
    @repository.add(build_permission)

    assert @repository.remove('claude.ai')
    refute @repository.exists?('claude.ai')
  end

  def test_remove_reports_false_when_the_host_was_not_allowed
    refute @repository.remove('claude.ai')
    refute @repository.remove(nil)
  end

  def test_all_returns_domain_objects_ordered_by_host
    @repository.add(build_permission(host: 'zebra.com'))
    @repository.add(build_permission(host: 'apple.com'))

    permissions = @repository.all

    assert(permissions.all? { |p| p.is_a?(Domain::HostPermission) })
    assert_equal %w[apple.com zebra.com], permissions.map(&:host)
  end

  def test_all_is_empty_initially
    assert_empty @repository.all
  end

  def test_records_survive_reconnection
    @repository.add(build_permission)
    @repository.close

    reopened = Repositories::NotificationPermissionRepository.new(db_path: @test_db_path)
    begin
      assert reopened.exists?('claude.ai')
    ensure
      reopened.close
    end
  end

  # The on-disk schema is adopted as-is.
  def test_uses_the_existing_notification_permissions_table
    @repository.add(build_permission)
    @repository.close

    db = SQLite3::Database.new(@test_db_path)
    begin
      assert_equal 1, db.get_first_value('SELECT COUNT(*) FROM notification_permissions')
    ensure
      db.close
    end
  end
end
