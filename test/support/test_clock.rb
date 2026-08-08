# A controllable clock for manager tests.
#
# Managers own the clock (see lib/managers/CLAUDE.md) and take it as
# `clock: -> { Time.now }`. Tests inject this instead and assert exact
# timestamps -- never sleep to make time pass.
#
#   @clock = TestClock.new(Time.at(1_700_000_000))
#   @manager = Managers::Something.new(clock: @clock)
#   @clock.advance(90)
class TestClock
  # @param start [Time] Time the clock starts at
  def initialize(start)
    @time = start
  end

  # @return [Time] The current time
  def call
    @time
  end

  # @param seconds [Integer] Seconds to move forward
  # @return [TestClock] self, so advance can be chained
  def advance(seconds)
    @time += seconds
    self
  end
end
