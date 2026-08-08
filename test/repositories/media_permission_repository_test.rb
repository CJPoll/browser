require 'minitest/autorun'
require 'fileutils'
require_relative '../../lib/repositories/media_permission_repository'

class MediaPermissionRepositoryTest < Minitest::Test
  GRANTED_AT = Time.at(1_700_000_000).freeze

  def setup
    @test_db_path = '/tmp/test_media_permissions.db'
    FileUtils.rm_f(@test_db_path)
    @repository = Repositories::MediaPermissionRepository.new(db_path: @test_db_path)
  end

  def teardown
    @repository&.close
    FileUtils.rm_f(@test_db_path)
  end

  def build_permission(host: 'meet.example.com', permission_type: :audio, granted_at: GRANTED_AT)
    Domain::HostPermission.new(
      host: host,
      permission_type: permission_type,
      granted_at: granted_at
    )
  end

  # --- add ---

  def test_add_returns_the_stored_permission_with_its_id
    stored = @repository.add(build_permission(permission_type: :audio_video))

    refute_nil stored.id
    assert_equal 'meet.example.com', stored.host
    assert_equal :audio_video, stored.permission_type
    assert_equal GRANTED_AT, stored.granted_at
  end

  def test_add_refuses_a_permission_the_host_already_has
    @repository.add(build_permission)

    assert_nil @repository.add(build_permission)
    assert_equal 1, @repository.all.size
  end

  # The three types are separate grants: allowing audio does not allow video.
  def test_one_host_may_hold_several_permission_types
    @repository.add(build_permission(permission_type: :audio))
    @repository.add(build_permission(permission_type: :video))

    assert_equal %i[audio video], @repository.all.map(&:permission_type).sort
  end

  # --- exists? ---

  def test_exists_is_specific_to_the_permission_type
    @repository.add(build_permission(permission_type: :audio))

    assert @repository.exists?('meet.example.com', :audio)
    refute @repository.exists?('meet.example.com', :video)
  end

  def test_exists_accepts_a_type_named_as_a_string
    @repository.add(build_permission(permission_type: :video))

    assert @repository.exists?('meet.example.com', 'video')
  end

  def test_exists_is_host_specific
    @repository.add(build_permission)

    refute @repository.exists?('other.com', :audio)
  end

  def test_exists_is_false_for_a_missing_host_or_type
    @repository.add(build_permission)

    refute @repository.exists?(nil, :audio)
    refute @repository.exists?('meet.example.com', nil)
  end

  # --- remove ---

  def test_remove_deletes_one_permission_type
    @repository.add(build_permission(permission_type: :audio))
    @repository.add(build_permission(permission_type: :video))

    assert @repository.remove('meet.example.com', :audio)

    refute @repository.exists?('meet.example.com', :audio)
    assert @repository.exists?('meet.example.com', :video)
  end

  def test_remove_without_a_type_deletes_every_permission_for_the_host
    @repository.add(build_permission(permission_type: :audio))
    @repository.add(build_permission(permission_type: :video))

    assert @repository.remove('meet.example.com')

    assert_empty @repository.all
  end

  def test_remove_leaves_other_hosts_alone
    @repository.add(build_permission(host: 'a.example.com'))
    @repository.add(build_permission(host: 'b.example.com'))

    @repository.remove('a.example.com')

    assert_equal %w[b.example.com], @repository.all.map(&:host)
  end

  def test_remove_reports_false_when_nothing_matched
    refute @repository.remove('meet.example.com', :audio)
    refute @repository.remove('meet.example.com')
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

    reopened = Repositories::MediaPermissionRepository.new(db_path: @test_db_path)
    begin
      assert reopened.exists?('meet.example.com', :audio)
    ensure
      reopened.close
    end
  end

  # The on-disk schema is adopted as-is, including the type column's string
  # values -- symbols would not match rows written by earlier versions.
  def test_stores_the_permission_type_as_a_string_in_the_existing_table
    @repository.add(build_permission(permission_type: :audio_video))
    @repository.close

    db = SQLite3::Database.new(@test_db_path)
    begin
      assert_equal 'audio_video',
                   db.get_first_value('SELECT permission_type FROM media_permissions')
    ensure
      db.close
    end
  end
end
