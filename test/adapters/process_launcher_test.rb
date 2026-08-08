require 'minitest/autorun'
require_relative '../../lib/adapters/process_launcher'

class AdaptersProcessLauncherTest < Minitest::Test
  # Records what would have been spawned instead of spawning it.
  class RecordingSpawner
    attr_reader :invocations

    def initialize(pid: 4242)
      @invocations = []
      @pid = pid
    end

    def call(*argv, **options)
      @invocations << [argv, options]
      @pid
    end
  end

  class RecordingDetacher
    attr_reader :detached

    def initialize
      @detached = []
    end

    def call(pid)
      @detached << pid
    end
  end

  def setup
    @spawner = RecordingSpawner.new
    @detacher = RecordingDetacher.new
    @launcher = Adapters::ProcessLauncher.new(spawner: @spawner, detacher: @detacher)
  end

  def test_launches_a_command_with_its_arguments
    @launcher.launch('ruby', '/path/to/simple_browser.rb')

    assert_equal [['ruby', '/path/to/simple_browser.rb'], {}], @spawner.invocations.first
  end

  def test_returns_the_process_id
    assert_equal 4242, @launcher.launch('ruby', 'script.rb')
  end

  # Each argument is passed separately, so a path with spaces or shell
  # metacharacters is data rather than something to execute.
  def test_passes_arguments_separately
    @launcher.launch('ruby', '/tmp/my script; rm -rf ~.rb')

    assert_equal ['ruby', '/tmp/my script; rm -rf ~.rb'], @spawner.invocations.first.first
  end

  def test_passes_spawn_options_through
    @launcher.launch('ruby', 'script.rb', chdir: '/tmp')

    assert_equal({ chdir: '/tmp' }, @spawner.invocations.first.last)
  end

  def test_leaves_a_plain_launch_attached
    @launcher.launch('ruby', 'script.rb')

    assert_empty @detacher.detached
  end

  # === Detached launches ===

  def test_detaches_a_background_launch
    @launcher.launch_detached('ruby', 'script.rb')

    assert_equal [4242], @detacher.detached
  end

  def test_detached_launch_spawns_the_same_command
    @launcher.launch_detached('ruby', 'script.rb', out: $stdout)

    assert_equal [['ruby', 'script.rb'], { out: $stdout }], @spawner.invocations.first
  end

  def test_detached_launch_returns_the_process_id
    assert_equal 4242, @launcher.launch_detached('ruby', 'script.rb')
  end
end
