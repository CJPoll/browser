# Managers

Orchestration between Repositories, Adapters, and Domain. See
`adrs/001-six-bucket-architecture.md` for the bucket rules; this file records
the conventions this directory follows.

> Several files currently in this directory are misfiled (SQLite
> pseudo-managers, pure logic, workers doing their own HTTP). The
> six-bucket remediation plan relocates them; the conventions below describe
> the target, not every file present today.

## Conventions

- **A manager takes a use case end to end**: fetch inputs through a repository
  or adapter, run them through Domain functions, persist outputs, return a
  Domain object. It holds no business rules of its own -- those belong in
  Domain -- and no SQL or IO -- those belong in a repository or adapter.
- **Injected collaborators**: repositories and adapters arrive through the
  constructor so tests can substitute mocks. Managers are the layer tested
  *with* mocks (Domain is tested without, repositories against real SQLite).
- **Namespacing**: existing managers are top-level constants
  (`DownloadCoordinator`, `AutocompleteManager`); new ones added by the
  remediation plan use `Managers::` (e.g. `Managers::QueueManager`). Expect a
  mix during the transition.

## Periodic work: the manager owns the policy, the Framework owns the timer

A manager exposes the operation and the interval; `BrowserWindow` schedules it
on the GTK main loop. No background thread, nothing to shut down, and the
operation stays directly testable.

```ruby
# Manager
CLEANUP_INTERVAL_SECONDS = 300
def cleanup_old_downloads(retention_days: RETENTION_DAYS)

# Framework
GLib::Timeout.add_seconds(DownloadCoordinator::CLEANUP_INTERVAL_SECONDS) do
  @download_coordinator.cleanup_old_downloads
  true # Keep repeating
end
```

## A manager may default its own collaborators

Framework must not name a Repository or an Adapter, so the manager provides a
default for each and tests override it:

```ruby
def initialize(repository = Repositories::DownloadRepository.new,
               clock: -> { Time.now },
               file_system: Adapters::FileSystem.new)
```

`BrowserWindow` then writes `DownloadCoordinator.new` and never mentions the
repository. The dependency is still injected -- it just has a production
default in the one place that is allowed to know it.

## Name the method after what the caller has

`Managers::SitePermissionManager` is the seam between "a site is asking for
something" (the caller holds a page URL) and "the user is managing a stored
record" (the caller holds a hostname). Rather than accept either everywhere
and guess, each method declares which it takes:

- `popups_allowed?(url)`, `allow_media(url, type)` -- **URL**; the manager
  resolves it with `Domain::UrlHost.host`.
- `revoke_popup_permission(host)`, `revoke_media_permission(host, type)` --
  **host**; by then there is no URL in play.
- `certificate_trusted?(host)`, `trust_certificate(host)` -- **host**
  throughout, because WebKit reports the failing host directly.

This killed a wart: the old permissions window had to fabricate
`"https://#{host}"` so a URL-only API could revoke a record it had listed by
host. Where a caller genuinely has either form -- WebKit's
`query-permission-state` supplies a security origin, not a page URL --
`Domain::UrlHost.host_or_bare_name` handles both, and the docstring says which
callers need it.

A manager is also the right place to reject input Domain considers invalid
before it reaches a repository: `allow_media` checks
`Domain::MediaPermissionType.valid?` so an unknown type cannot land in the
table as an unrevokable row.

## Managers own the clock

Domain never reads the clock (see `lib/domain/CLAUDE.md`), so the manager that
drives a use case supplies the time. This is the one place a default clock
belongs -- it is the boundary between the pure core and the real world.

```ruby
class DownloadCoordinator
  def initialize(repository, clock: -> { Time.now })
    @repository = repository
    @clock = clock
  end

  def mark_completed(download_id)
    download = @repository.find_by_id(download_id)
    return nil unless download

    @repository.save(download.mark_completed(now: @clock.call))
  end
end
```

Conventions: the keyword is `clock:`, the default is `-> { Time.now }`, and
the object only needs to respond to `#call`. Call `@clock.call` at the point
of use rather than caching it, so long-lived managers do not freeze time.

Tests inject a controllable clock and assert exact timestamps:

```ruby
class TestClock
  def initialize(start)
    @time = start
  end

  def call
    @time
  end

  def advance(seconds)
    @time += seconds
    self
  end
end

@clock = TestClock.new(Time.at(1_700_000_000))
@coordinator = DownloadCoordinator.new(@repository, clock: @clock)
@clock.advance(90)
assert_equal Time.at(1_700_000_090), @coordinator.mark_completed(id).completed_at
```

**Never** use `Process.sleep`/`sleep` to make time pass in a test -- advance
the injected clock.
