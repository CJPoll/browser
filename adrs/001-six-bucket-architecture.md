# ADR 001 -- Six-Bucket Architecture

## Status

Accepted.

## Context

This browser grew from a monolithic `simple_browser.rb` into `lib/`
subdirectories, but without a written rule for what belongs where. An audit
(2026-08) found the predictable drift: business logic tangled with GTK signal
handlers, raw SQL executed from classes labeled "managers", UI widgets writing
directly to persistence, and pure algorithms duplicated across buckets.

This ADR adapts the five-bucket architecture from `walt_ui` (ADR 001 there)
to this Ruby/GTK codebase, with one addition: **Repository** is promoted from
a sub-category of Side Effects to its own bucket. The walt_ui ADR already
treated repositories differently in one respect (repositories are not mocked
in tests; other adapters are); this makes the distinction structural.

## Decision

Every class or module belongs to exactly one of these six buckets:

1. **Framework** -- Code glued to GTK / WebKitGTK that owns the event
   lifecycle: `BrowserApplication`, `BrowserWindow`, `Tab`, and everything in
   `lib/handlers/` (signal handlers are this codebase's equivalent of
   controller actions / `handle_event/3`). Framework wires UI callbacks to
   Manager calls.
2. **UI Components** (`lib/ui/`) -- Presentational GTK widgets. They receive
   data and render it; user actions bubble up through callbacks that
   Framework binds. They do not orchestrate work themselves.
3. **Repositories** (`lib/repositories/`) -- Wraps a database (SQLite here).
   A repository takes Domain objects and returns Domain objects, and
   encapsulates all knowledge of how to interact with its specific database
   or set of tables: SQL, schema creation, migrations, transactions. Raw rows
   never leak past its boundary. Repositories are tested against a real
   in-memory database, never mocked.
4. **Adapters** (`lib/adapters/`) -- All other side effects: external
   processes (`notify-send`, `xdg-open`, `fzf`), HTTP clients, file stores
   (settings/session JSON), file-based IPC. Adapters also take and return
   Domain objects (or primitives). Adapters are mocked in tests.
5. **Domain** (`lib/domain/`) -- Side-effect-free business logic. Pure
   functions, immutable structs, value objects. Given the same inputs it
   always returns the same outputs. No IO, no clock reads, no database, no
   GTK. The current time is a **required** parameter (`now`/`now:`), never a
   defaulted one -- a default is still a clock read. The calling Manager owns
   the clock; see `Domain::Frecency.score` and `Domain::Download`.
6. **Managers** (`lib/managers/`) -- Orchestration between Repositories,
   Adapters, and Domain. A Manager takes a use case end to end: fetch inputs
   through a repository or adapter, pass them through Domain functions,
   persist outputs, return a Domain object.

### Allowed calls

| From \ To    | Framework | UI  | Repositories | Adapters | Domain | Managers |
|--------------|-----------|-----|--------------|----------|--------|----------|
| Framework    | --        | yes | **no**       | **no**   | yes    | yes      |
| UI           | no        | yes | **no**       | **no**   | yes    | **no**   |
| Repositories | no        | no  | yes¹         | no       | yes    | **no**   |
| Adapters     | no        | no  | no           | yes      | yes    | **no**   |
| Domain       | **no**    | no  | **no**       | **no**   | yes    | **no**   |
| Managers     | no        | no  | yes          | yes      | yes    | yes      |

¹ Only repositories sharing the same database file (e.g. the queue and tag
repositories both operate on `queue.db`) may compose, typically by sharing a
connection.

### Specific constraints

- Framework **MUST NOT** call Repositories or Adapters directly. Go through
  a Manager.
- Framework **MAY** call Domain objects for simple response logic (a
  lightweight predicate, formatting a struct).
- UI Components **MAY** call Domain objects for rendering and simple view
  logic. The Domain object must have been retrieved by a Manager (via
  Framework) first.
- UI Component actions (button clicks, row activation, drag-and-drop) are
  bound to Framework code via callbacks -- the UI does not orchestrate work
  itself, and it **MUST NOT** hold references to Managers, Repositories, or
  Adapters.
- Repositories own their SQL, schema, and migrations exclusively. No SQL
  string exists outside `lib/repositories/`.
- Repositories and Adapters receive Domain objects and return Domain
  objects. They do not leak raw database rows, HTTP responses, or external
  payloads past their boundary.
- Domain objects **MUST NOT** call anything outside Domain, read the clock,
  or perform IO of any kind.
- Managers coordinate; they do not perform IO themselves. A Manager that
  opens a socket, executes SQL, spawns a process, or reads a file is doing a
  Repository's or Adapter's job.

### Framework/UI file separation

Mirroring walt_ui's LiveView rule: Framework owns event handling and state;
the rendered output belongs in `lib/ui/` in a separate file. Constructing a
non-trivial dialog or widget tree inline in `BrowserWindow` is the GTK
equivalent of inlining a large `~H` template in a LiveView module -- extract
it to a `lib/ui/` class. Small, trivial widget construction is tolerated.

## Bucket assignments for existing code

Current classes that already conform:

| File | Bucket |
|------|--------|
| `lib/domain/frecency.rb` | Domain (conforms -- `now` is a required parameter) |
| `lib/domain/download.rb` | Domain (conforms -- `created_at:`/`now:` supplied by the caller) |
| `lib/domain/url_matcher.rb` | Domain (conforms) |
| `lib/domain/url_host.rb` | Domain (conforms) |
| `lib/domain/url_classifier.rb` | Domain (conforms) |
| `lib/domain/external_schemes.rb` | Domain (conforms) |
| `lib/domain/oauth_popup.rb` | Domain (conforms) |
| `lib/domain/tag_name.rb` | Domain (conforms) |
| `lib/domain/download_badge.rb` | Domain (conforms) |
| `lib/domain/download_controls.rb` | Domain (conforms) |
| `lib/domain/host_permission.rb` | Domain (conforms) |
| `lib/domain/media_permission_type.rb` | Domain (conforms) |
| `lib/domain/queue_entry.rb` | Domain (conforms -- `added_at:` supplied by the caller) |
| `lib/domain/tag.rb` | Domain (conforms) |
| `lib/domain/tag_usage.rb` | Domain (conforms) |
| `lib/domain/queue_traversal.rb` | Domain (conforms) |
| `lib/repositories/download_repository.rb` | Repositories |
| `lib/repositories/popup_exception_repository.rb` | Repositories |
| `lib/repositories/media_permission_repository.rb` | Repositories |
| `lib/repositories/notification_permission_repository.rb` | Repositories |
| `lib/repositories/certificate_exception_repository.rb` | Repositories |
| `lib/repositories/queue_database.rb` | Repositories (shared `queue.db` connection and schema) |
| `lib/repositories/queue_repository.rb` | Repositories |
| `lib/repositories/tag_repository.rb` | Repositories |
| `lib/adapters/fzf_adapter.rb` | Adapters |
| `lib/adapters/file_system.rb` | Adapters |
| `lib/managers/autocomplete_manager.rb` | Managers |
| `lib/managers/download_coordinator.rb` | Managers |
| `lib/managers/site_permission_manager.rb` | Managers |
| `lib/managers/queue_manager.rb` | Managers |
| `lib/managers/queue_navigation_manager.rb` | Managers |
| `lib/handlers/download_handler.rb` | Framework (WebKit signals -> Manager) |
| `lib/ui/download_list_view.rb` | UI (data in, intent callbacks out) |
| `lib/ui/site_permissions_window.rb` | UI (data in, intent callbacks out) |

Target classification for the current pseudo-managers. Each wraps its own
table(s) and becomes its own repository -- they rhyme today, but they are
different tables with different semantics:

| Current file | Target |
|--------------|--------|
| The four permission pseudo-managers | Deleted -- superseded by the four repositories above plus `Managers::SitePermissionManager`, which resolves URLs to hosts via `Domain::UrlHost` and owns the clock for grants |
| `history_manager.rb` (root) | `Repositories::HistoryRepository` (`sites`, `pages`, `visits`); its authority logic already lives in `Domain::UrlHost` |
| `queue_manager.rb` (root) | Deleted -- superseded by `Repositories::QueueRepository` + `Repositories::TagRepository` over a shared `Repositories::QueueDatabase`, plus `Managers::QueueManager` and `Managers::QueueNavigationManager` |
| `download_manager.rb` (root) | Deleted -- superseded by `Repositories::DownloadRepository` + `DownloadCoordinator`, wired in through `DownloadHandler` |
| `lib/managers/session_manager.rb` | Adapters (JSON file store, not a database) |
| `lib/managers/settings_manager.rb` | Adapters (JSON file store, not a database) |
| `lib/managers/auto_tagger.rb` | Domain (already pure) |
| `lib/managers/article_extractor_js.rb` | Domain (constant script module, already pure) |

## Examples

### Correct

```ruby
# Framework (BrowserWindow) binds a UI callback to a Manager call
@queue_list_view = UI::QueueListView.new(
  on_entry_removed: ->(entry_id) { @queue_manager.remove_entry(entry_id) }
)

# Manager orchestrates Repository + Domain: it fetches the state, Domain
# decides, the Manager applies the decision
class Managers::QueueNavigationManager
  def initialize(queue_manager)
    @queue_manager = queue_manager
  end

  def next_entry(current_url)
    Domain::QueueTraversal.next_after(@queue_manager.all, current_url)
  end
end

# Repository takes and returns Domain objects; SQL lives only here, and so
# does the row -> Domain mapping (Domain must not know about columns)
class Repositories::QueueRepository
  def find_by_id(id)
    row = @database.get_first_row("SELECT #{COLUMNS} FROM queue_entries WHERE id = ?", [id])
    row && build_entry(row)
  end
end

# Domain is pure; the clock is a required parameter, never a default
module Domain::Frecency
  def self.score(visit_count, last_visited_at, now)
    # pure computation
  end
end

# The Manager owns the clock and supplies it to Domain.
# A default belongs here, at the call boundary -- not inside Domain.
class AutocompleteManager
  def initialize(history_manager, clock: -> { Time.now })
    @clock = clock
  end

  def build_candidates
    now = @clock.call.to_i
    pages.map { |p| Domain::Frecency.score(p.visit_count, p.last_visited_at, now) }
  end
end
```

### Incorrect

```ruby
# BAD: UI Component calling a Manager (or worse, a Repository) directly.
# Bubble the action up through a callback and let Framework orchestrate.
class UI::QueueListView
  def on_remove_clicked(entry_id)
    @queue_manager.remove_by_id(entry_id)   # UI must not orchestrate
  end
end

# BAD: Framework performing side effects inline
class BrowserWindow
  def handle_web_notification(title, body)
    system("notify-send", title, body)      # belongs in an Adapter
  end
end

# BAD: a "Manager" that is really a Repository
# (the shape the four permission pseudo-managers had before they were split
# into repositories + Managers::SitePermissionManager)
class Managers::SomePermissionManager
  def allow(url)
    @db.execute("INSERT INTO some_permissions ...")  # SQL outside lib/repositories/
  end
end

# BAD: Domain reading the clock
class Domain::Download
  def mark_completed
    with(state: :completed, completed_at: Time.now)  # inject the time
  end
end
```

## Consequences

### Benefits

- **Testability.** Domain is pure and trivial to test. Managers are tested
  with mocked adapters and repositories-or-mocks. Repositories are tested
  against in-memory SQLite. This matches the existing testing-pyramid
  conventions.
- **Replaceability.** Swapping SQLite for something else, or `notify-send`
  for another notifier, touches one bucket.
- **Readability.** The module path tells you what kind of code you are
  reading, and the blast radius of a change is bounded by the bucket.
- **The Repository/Adapter split is load-bearing in tests.** Repositories
  are exercised for real; adapters are mocked. Making them separate buckets
  makes that rule mechanical.

### Tradeoffs

- More classes. A permission check becomes a repository, a manager, and a
  Framework call site. This is intentional; four copy-paste SQLite
  "managers" are the evidence that the shortcut does not stay cheap.
- Requires discipline at code review; there is no enforcement bot in this
  repository yet.

## References

- `~/dev/walt_ui/backend/adrs/001-five-bucket-architecture.md` (the parent
  five-bucket ADR this adapts)
- Hexagonal Architecture / Ports and Adapters (Alistair Cockburn)
- The 2026-08 architecture audit conversation that catalogued current
  violations
