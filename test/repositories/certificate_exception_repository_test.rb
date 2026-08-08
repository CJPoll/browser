require 'minitest/autorun'
require 'fileutils'
require_relative '../../lib/repositories/certificate_exception_repository'

class CertificateExceptionRepositoryTest < Minitest::Test
  GRANTED_AT = Time.at(1_700_000_000).freeze

  def setup
    @test_db_path = '/tmp/test_certificate_exceptions.db'
    FileUtils.rm_f(@test_db_path)
    @repository = Repositories::CertificateExceptionRepository.new(db_path: @test_db_path)
  end

  def teardown
    @repository&.close
    FileUtils.rm_f(@test_db_path)
  end

  def build_permission(host: 'localhost', granted_at: GRANTED_AT)
    Domain::HostPermission.new(host: host, granted_at: granted_at)
  end

  def test_add_returns_the_stored_permission_with_its_id
    stored = @repository.add(build_permission)

    refute_nil stored.id
    assert_equal 'localhost', stored.host
    assert_equal GRANTED_AT, stored.granted_at
  end

  def test_add_refuses_a_host_that_already_has_an_exception
    @repository.add(build_permission)

    assert_nil @repository.add(build_permission)
    assert_equal 1, @repository.all.size
  end

  def test_exists_reflects_what_was_added
    refute @repository.exists?('localhost')

    @repository.add(build_permission)

    assert @repository.exists?('localhost')
    refute @repository.exists?('other.internal')
  end

  # Certificate exceptions are keyed on host including the port, since a bad
  # certificate is served by a specific listener.
  def test_a_host_with_a_port_is_a_distinct_key
    @repository.add(build_permission(host: 'localhost:8443'))

    assert @repository.exists?('localhost:8443')
    refute @repository.exists?('localhost')
  end

  def test_exists_is_false_for_a_missing_host
    refute @repository.exists?(nil)
  end

  def test_remove_reports_the_deletion
    @repository.add(build_permission)

    assert @repository.remove('localhost')
    refute @repository.exists?('localhost')
  end

  def test_remove_reports_false_when_there_was_no_exception
    refute @repository.remove('localhost')
    refute @repository.remove(nil)
  end

  def test_all_returns_domain_objects_ordered_by_host
    @repository.add(build_permission(host: 'zebra.internal'))
    @repository.add(build_permission(host: 'apple.internal'))

    permissions = @repository.all

    assert(permissions.all? { |p| p.is_a?(Domain::HostPermission) })
    assert_equal %w[apple.internal zebra.internal], permissions.map(&:host)
  end

  def test_all_is_empty_initially
    assert_empty @repository.all
  end

  def test_records_survive_reconnection
    @repository.add(build_permission)
    @repository.close

    reopened = Repositories::CertificateExceptionRepository.new(db_path: @test_db_path)
    begin
      assert reopened.exists?('localhost')
    ensure
      reopened.close
    end
  end

  # The on-disk schema is adopted as-is.
  def test_uses_the_existing_certificate_exceptions_table
    @repository.add(build_permission)
    @repository.close

    db = SQLite3::Database.new(@test_db_path)
    begin
      assert_equal 1, db.get_first_value('SELECT COUNT(*) FROM certificate_exceptions')
    ensure
      db.close
    end
  end
end
