# frozen_string_literal: true

module Adapters
  # Starts another process.
  #
  # Used to relaunch the browser after a code reload. The command is always
  # passed as argv rather than as a shell string, so arguments cannot be
  # reinterpreted as shell syntax.
  class ProcessLauncher
    # Spawns a command as argv, never through a shell.
    SYSTEM_SPAWNER = ->(*argv, **options) { spawn(*argv, **options) }

    # Reaps the child so it does not become a zombie.
    SYSTEM_DETACHER = ->(pid) { Process.detach(pid) }

    # @param spawner [#call] Receives the command, its arguments and spawn options
    # @param detacher [#call] Receives a process id to detach
    def initialize(spawner: SYSTEM_SPAWNER, detacher: SYSTEM_DETACHER)
      @spawner = spawner
      @detacher = detacher
    end

    # Starts a process and leaves it as a child of this one
    #
    # @param argv [Array<String>] Command and arguments
    # @param options [Hash] Spawn options (`chdir:`, `out:`, ...)
    # @return [Integer] The new process id
    def launch(*argv, **options)
      @spawner.call(*argv, **options)
    end

    # Starts a process that outlives this one's interest in it
    #
    # @param argv [Array<String>] Command and arguments
    # @param options [Hash] Spawn options (`chdir:`, `out:`, ...)
    # @return [Integer] The new process id
    def launch_detached(*argv, **options)
      pid = @spawner.call(*argv, **options)
      @detacher.call(pid)
      pid
    end
  end
end
