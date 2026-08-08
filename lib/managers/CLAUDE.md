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

Tests inject a controllable clock and assert exact timestamps. `TestClock`
lives in `test/support/test_clock.rb` -- require it, do not redeclare it (three
copies at top level made `ruby -w` shout about redefined methods):

```ruby
require_relative '../support/test_clock'

@clock = TestClock.new(Time.at(1_700_000_000))
@coordinator = DownloadCoordinator.new(@repository, clock: @clock)
@clock.advance(90)
assert_equal Time.at(1_700_000_090), @coordinator.mark_completed(id).completed_at
```

**Never** use `Process.sleep`/`sleep` to make time pass in a test -- advance
the injected clock.

## A manager may drive another manager

`Managers::QueueNavigationManager` takes `Managers::QueueManager`, not the
queue repositories. Traversal is a use case *on top of* the queue, so it goes
through the queue's public API and inherits its validation rather than
re-wiring two repositories and a clock.

The rule this follows: reach for a second manager when the thing you need is
already a use case; reach for a repository when you need storage that no
manager exposes. A manager that wires up another manager's repositories is
the shape to avoid -- it means the first manager's rules can be bypassed.

## Fetch the state, let Domain decide, apply the decision

The manager's body should read as three steps with no branching of its own:

```ruby
def next_entry(current_url)
  Domain::QueueTraversal.next_after(@queue_manager.all, current_url)
end
```

Wrap-around, "what does next mean when the current page is not in the queue",
and exact-vs-loose URL matching are all rules, so they are in Domain and get
exhaustive tests without a database. What is left here is the fetch. When a
manager method grows an `if`, ask which Domain module the condition belongs
to.

## Constructor: production default, plus a seam for mocks

Managers default their own collaborators so Framework never names a
repository (see above). When a manager owns *several* repositories over a
shared resource, keep both doors open:

```ruby
def initialize(database: nil, queue_repository: nil, tag_repository: nil,
               clock: -> { Time.now })
```

- production: `Managers::QueueManager.new` -- opens the real `queue.db`
- widget tests: `.new(database: Repositories::QueueDatabase.new(db_path: tmp))`
- manager tests: `.new(queue_repository: mock, tag_repository: mock)`

Build the database only when the repositories were not supplied, or a manager
test opens a real file it never uses. A manager that opened the database gets
a `close`; one built from injected repositories has nothing to close.

## Symbol results are an API; keep them when you replace the implementation

`add` returns `:added`/`:already_exists`/`:invalid_url`, `assign_tag` returns
five different symbols. Repositories underneath return booleans or nil
(`repository.add` -> object-or-nil, `repository.assign` -> boolean); the
manager translates. The translation is where "why not" lives -- an unknown
entry and an unknown tag are both a false from the repository, and callers
need to tell them apart.

## Idempotence policy belongs to the manager, not the caller

WebKit reports one page arrival more than once -- `load-changed` fires, then
`notify::title` fires again when a single-page app rewrites the title.
`BrowserWindow` used to carry a `@last_recorded_visit` key and an `unless`
around each call site, which meant every new caller had to remember the rule.
It now lives in `Managers::HistoryManager`, and the caller reads:

```ruby
if @history_manager.record_visit(uri, title) != :duplicate
  @favicon_manager.fetch_and_save_favicon(uri) if @favicon_manager
end
```

Two details worth copying:

- The **symbol result is what makes the move possible**. `:recorded` /
  `:duplicate` / `:invalid_url` lets the Framework keep the one thing that is
  genuinely its business (fetching a favicon on a fresh arrival) without
  knowing why a call was skipped.
- **Record the key even when the input is rejected.** An unusable URL cannot
  become usable on the next identical report, so remembering it keeps a warn
  out of every signal. That is a decision, so it gets a comment and a test.

## When a manager adds a policy, other tests must seed beneath it

`AutocompleteManagerTest` built visit counts by recording the same URL fifty
times. Once `HistoryManager` deduplicated consecutive identical visits, that
seeding silently produced one visit and the ranking assertions went hollow.
The fix is to seed through the **repository** and keep the manager as the
object under test:

```ruby
# The manager deduplicates identical consecutive visits, which is exactly
# what building up a visit count needs to bypass.
def record_visit(url, title, times: 1)
  authority = Domain::UrlHost.authority(URI.parse(url))
  times.times { @repository.record_visit(url: url, authority: authority, title: title, now: NOW) }
end
```

When you add a rule to a manager, grep for the tests that were using it as a
convenient way to fill a database.
