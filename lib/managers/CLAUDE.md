# Managers

Orchestration between Repositories, Adapters, and Domain. See
`adrs/001-six-bucket-architecture.md` for the bucket rules; this file records
the conventions this directory follows.

> Two files in this directory are misfiled and stayed that way:
> `favicon_manager.rb` and `web_context_manager.rb` both reach straight into
> WebKit, which makes them Framework. The six-bucket remediation left them
> alone because each is a thin WebKit configuration wrapper with no business
> rules to pull out -- there is nothing to separate. Do not treat them as
> examples; if either grows policy, that policy belongs in a real manager and
> the WebKit half belongs in Framework.

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

## Background work: the unit of work is public, the thread is not

`Managers::QueueMetadataWorker` runs on its own thread (unlike the periodic
work above, it must not block the GTK main loop while a page is fetched). The
thread is still not the interesting part, so the work it does is a public
method and the thread merely calls it:

```ruby
def enqueue(entry_id, url) = @work_queue.push({ id: entry_id, url: url })

# The unit of work `enqueue` schedules; public because it is the worker's
# actual behaviour, and the thread is only how it gets run.
def process(entry_id, url)
```

Every test of what the worker *does* calls `process` directly and is
deterministic. One test per lifecycle guarantee (an enqueued item is picked
up, one failure does not kill the loop, `stop` ends the thread) still uses the
thread, with a polling loop. Before this split the tests reached in with
`send(:fetch_metadata, ...)` -- the private-method `send` in a test is usually
a sign that the object's real API is missing a name.

**Injecting the main-thread scheduler** is what makes the callback testable at
all, since nothing pumps the GTK main loop in a test process:

```ruby
MAIN_THREAD_SCHEDULER = lambda do |&block|
  GLib::Idle.add { block.call; false }
end

def initialize(..., scheduler: MAIN_THREAD_SCHEDULER)
```

The test passes `->(&block) { scheduled << block }` and asserts both halves:
that the callback was *handed to* the main thread rather than run on the
worker thread, and that running it invokes the callback.

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

## A thin manager over a single adapter is still worth having

Framework must not call an Adapter, so an effect with no rules around it --
handing a `spotify://` URI to the desktop -- still needs a manager in front of
it. Keep the wrapper honest rather than ceremonial:

- **Name the methods after what the caller has.** `ExternalOpener` exposes
  `open_uri`, `open_path` and `open_containing_directory` over one adapter
  method, so no caller has to work out whether it should be passing a URI, a
  file, or the folder a file is in. `open_containing_directory` is where
  `File.dirname` lives -- previously written out at all three call sites.
- **The decision to act belongs to the manager**, so the "nothing to open"
  guard lives there and is tested with a dumb mock. The adapter keeps its own
  guard as protection against a nil reaching `system`, tested separately.
- **Let it grow into the seam it will need.** `Managers::BrowserRestarter`
  wraps one launch, but it also fixes the order (save the session, *then*
  start the replacement) that used to be spelled out in `BrowserWindow`.

## Two callers, two methods -- name the difference

`Managers::PdfBookmarkManager` writes bookmarks into a PDF for two callers
that need different things, and says so in the method names rather than in a
flag:

- `add_bookmarks(path, markdown)` -- the user chose a PDF and is waiting, so it
  runs here and returns `:added`/`:failed`. The Framework puts it on a thread
  because it is slow, which is a UI concern and stays with the UI.
- `add_bookmarks_for_print(output_uri, markdown)` -- a print job just finished,
  so the work goes to a *separate process*: it is unattended, and a crash in a
  PDF library must not take the browser with it.

The policy that is genuinely the manager's is which jobs qualify at all -- a
job that went to a real printer, produced a `.ps`, or came from a page that was
not markdown gets `:not_a_pdf`/`:no_markdown` and no writer call. Those three
answers were an `if` with three clauses inside a WebKit signal handler.

## The Framework's watermark belongs to the manager

`BrowserApplication` used to carry `@last_ipc_check` and compare timestamps
itself, which meant the rule "act on a request exactly once" lived in a GTK
timer callback. `Managers::IpcManager` owns it now:

```ruby
def take_pending_request
  message = @ipc_file.read
  return nil unless message&.newer_than?(@watermark)

  @watermark = message.timestamp
  @ipc_file.delete
  message
end
```

The method name is the contract -- *take*, not *read*: the caller gets each
request once, and does not have to remember to clear anything. The same
manager also publishes (a second invocation calls `publish` and exits), so
both ends of the exchange, and the message format, stay in one place.

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

## Per-widget state: name the widget with a key, never hold it

`Managers::MarkdownManager` remembers what each webview is showing (which
document, rendered or source) without ever seeing a webview: the handler
passes `webview.object_id` as an opaque `view_key`, and the manager treats it
as a hash key it never interprets.

That one indirection is what lets the manager be tested with `:view_1` and
`:view_2` and no GTK at all, while the Framework keeps the only reference to
the widget -- which it has to, since it is also the only bucket that knows
when the widget goes away and the state should be forgotten.

The pair to get right is `render`/`forget`: state keyed by a widget leaks
unless the Framework tells the manager the widget has navigated away. Give the
manager the explicit `forget(view_key)` rather than any cleverness about
liveness; a bucket that cannot see the widget cannot notice it dying.

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

## Two steps with the user in between: return the prompt, keep nothing

`Managers::PasskeyManager` cannot finish a request without the user's
consent, and a manager must neither hold a widget nor wait for one. So
`prepare` does every check that needs no user and returns a
`Domain::PasskeyPrompt` carrying everything finishing will need (request,
origin, RP ID, candidate passkeys). The Framework shows it and later hands it
back to `register`, `authenticate` or `cancel`, each of which returns the
`Domain::PasskeyResponse` for the page.

- **No pending state in the manager.** A page that navigates away leaks
  nothing here, and every branch is a plain call in the test.
- **The finishing call re-checks the prompt.** `authenticate` raises unless
  the passkey is one of the prompt's candidates, so the Framework cannot sign
  with a key the prompt never offered.
- **Failures the manager cannot fix become answers.** A store that is not
  signed in turns into a rejection with a page-facing error plus a `warn`;
  an exception must never escape into a WebKit signal handler.
- **The clock and the random source are both injected** (`clock:`,
  `random:`), so the test asserts the exact credential id bytes and creation
  time rather than their shape.

## Re-check the world at the finishing call, not just at the start

`Managers::LoginFillManager` is the same two-steps-with-the-user shape, with a
security twist: the state it gated on at `prepare` can change while the bar is
on screen, so the finishing call re-checks it before doing anything expensive
or irreversible.

- `prepare(origin:, probe_json:)` gates on a secure origin and a password
  field, lists logins, matches by site, and returns a `LoginFillPrompt` or a
  `LoginFillNotice`. It **never fetches a password** -- a test asserts the
  store's `password_for` is untouched, so the secret is read only after the
  user confirms.
- `credential_for(prompt, index, live_origin:)` takes the origin **again** and
  returns `:origin_changed` (without calling the store) when it no longer
  matches the prompt's origin -- the page may have navigated under the bar. It
  also re-validates the index against the prompt (`candidate_at` raises for an
  index the prompt never offered, a Framework bug), so nothing is fetched for
  an account the user was not shown.
- `conclude(report_json)` reads what the page reported and answers `nil`
  (filled) or a `:fill_failed` notice.

Failures the manager cannot fix become named notices: each store error class
(`NotInstalled`, `NotSignedIn`, `TimedOut`, everything else -> `:unavailable`)
maps to a reason, logged as the reason symbol only -- never the label, the
credential, or the exception message that might quote a secret.

## Split "what is stored" from "what to do when it is asked for"

`Managers::SitePermissionManager` owns the stored permissions;
`Managers::PermissionRequestManager` and `Managers::PopupManager` own what
happens when a site asks for one. The second pair drives the first (see "a
manager may drive another manager") and each method is the same three lines:

```ruby
def notification_request(page_url)
  Domain::PermissionDecision.for(
    url: page_url,
    granted: @site_permissions.notifications_allowed?(page_url)
  )
end
```

Why the split is worth two extra files: the storage manager is called by the
permissions *window* (list, revoke) and the request managers are called by
WebKit *signals*. They change for different reasons, and the request side has
policy the storage side should never grow -- OAuth routing, which permission
names this browser answers a state query for, what to do when a URL has no
host.

The rule for what stays in the Framework: **the manager decides, the Framework
applies**. Opening a window, calling `request.allow`, or handing WebKit a
`PermissionState` all need objects only `BrowserWindow` holds, so the manager
returns a decision and never sees a widget. That is also what makes the policy
testable -- `test/managers/permission_request_manager_test.rb` covers every
branch with no GTK in the process.

Where a manager answers a question WebKit asks about *itself*, keep the symbol
vocabulary WebKit uses (`:granted` / `:prompt` / `:unhandled`) rather than the
decision object -- the Framework's job there is a one-to-one translation into
`WebKit2Gtk::PermissionState`, and `:unhandled` is genuinely different from
"no". Note the query supplies a **security origin**, not a page URL, which is
why that path goes through `Domain::UrlHost.host_or_bare_name`.

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
