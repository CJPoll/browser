# Repositories

Database-backed persistence. See `adrs/001-six-bucket-architecture.md` for the
bucket rules; this file records the conventions this directory follows.

## Conventions

- **Namespace**: every class lives under `module Repositories` (nested module
  form, not `class Repositories::Foo`, so the module is always defined).
  Reference from other buckets as `Repositories::DownloadRepository`.
- **Domain objects at the boundary**: methods take and return Domain objects.
  Rows/hashes never escape the class. Row -> struct mapping lives in a private
  `build_*` method here, not on the Domain object (Domain must not know SQL).
- **SQL exclusivity**: every SQL string in the codebase lives in this
  directory. No other bucket may hold one.
- **Schema ownership**: `CREATE TABLE IF NOT EXISTS` and any migrations run in
  a private `setup_database` from `initialize`. Existing on-disk databases in
  `~/.local/share/toy-browser/` are adopted as-is -- do not change schemas.
- **Injectable path**: `initialize(db_path: DB_PATH)` with a `DB_PATH` constant
  default. Tests pass a temp path; production uses the default.
- **`require 'fileutils'`** is needed when the class calls `FileUtils.mkdir_p`
  to create the DB directory. It is easy to miss because GTK code elsewhere
  loads it transitively at runtime but not in unit tests.

## Connection boilerplate is shared; schemas are not

`SqliteConnection` provides `connect(db_path)` (mkdir, open, hash rows, UTF-8
pragma) and `close`. Include it rather than repeating six lines in every
class:

```ruby
class PopupExceptionRepository
  include SqliteConnection

  DB_PATH = File.join(Dir.home, '.local', 'share', 'toy-browser', 'popups.db')

  def initialize(db_path: DB_PATH)
    connect(db_path)
    setup_database
  end
```

What it deliberately does **not** do is take the table name. The four
permission stores look alike today, but they are four tables with different
keys and different semantics (media is keyed on `(host, type)`, the rest on
`host` alone); a parameterised base class would make that difference invisible
and the next divergence painful. Each repository declares its own schema and
owns every SQL string touching it.

## Naming for a host-keyed store

The permission repositories settled on a small shared vocabulary. Reuse it:

| Method | Returns |
| --- | --- |
| `exists?(key)` | Boolean; `false` for a nil key rather than raising |
| `add(domain_object)` | the stored object **with its id**, or `nil` if the row already existed |
| `remove(key)` | Boolean -- whether anything was deleted |
| `all` | `Array<DomainObject>`, ordered for display |

`add` returning `nil` rather than `false` on a duplicate is what lets a caller
write `repository.add(...)` and get a Domain object back on success; the
uniqueness constraint is caught as `SQLite3::ConstraintException` and
translated here, not left to leak into a Manager.

## Testing

Repositories are **never mocked** (ADR 001). Test against a real SQLite file:

```ruby
def setup
  @test_db_path = '/tmp/test_downloads.db'
  FileUtils.rm_f(@test_db_path)
  @repository = Repositories::DownloadRepository.new(db_path: @test_db_path)
end

def teardown
  @repository&.close
  FileUtils.rm_f(@test_db_path)
end
```

Tests live in `test/repositories/`, mirroring this directory.

## Time handling

Timestamps are stored as integer Unix seconds. Private `to_timestamp` /
`from_timestamp` helpers convert at the boundary so Domain objects always see
`Time` instances.

## Two repositories, one database file

`queue.db` holds `queue_entries` on one side and `tags` +
`queue_entry_tag_assignments` on the other. They are separate concerns, so
they are separate repositories -- but they are one file, one transaction
scope, and one schema history, so they share one connection object:

```ruby
database = Repositories::QueueDatabase.new
Repositories::QueueRepository.new(database)
Repositories::TagRepository.new(database)
```

`QueueDatabase` owns what belongs to the *file* rather than to a table:
connecting, the pragmas, the lock, and the schema including migrations. That
last part is not a compromise -- the v1 -> v2 migration creates the tag tables
*and* adds `queue_entries.date` in one transaction, so no single repository
could own it. It exposes `execute`/`get_first_row`/`get_first_value`/
`transaction`/`synchronize`; every SQL string still lives in the repository
whose table it touches.

Prefer this over `SqliteConnection` when repositories share a file;
`SqliteConnection` is for the one-repository-one-file case.

## Repositories do not join across each other's tables

`TagRepository#entry_ids_with_all_tags` returns entry **ids**, and the
manager passes them to `QueueRepository#find_all_by_ids`. The single joined
query would have been shorter, but it would have put `queue_entries` SQL and
a second copy of the row -> `QueueEntry` mapping inside the tag repository.
Two queries and one owner per table is the trade this codebase takes.

## Locking: a reentrant Monitor, held across read-then-write

The queue is written from the metadata worker's background thread as well as
the GTK main loop. `QueueDatabase#synchronize` uses a `Monitor` (reentrant),
which is what lets a repository wrap a whole read-then-write sequence without
deadlocking on the nested calls inside it:

```ruby
def unassign(entry_id, tag_id)
  @database.synchronize do
    @database.execute('DELETE FROM ...', [entry_id, tag_id])
    @database.changes > 0          # meaningless if another thread got in between
  end
end
```

`changes` and `last_insert_row_id` are only meaningful inside the block that
produced them. Same for a find-then-delete: take the lock around both.

## Gotcha: `SQLite3::Database#transaction` returns true, not your block

```ruby
stored = nil
@database.transaction { stored = entry.with(id: ..., position: ...) }
stored   # <- the block's value has to come out through a local
```

The gem's `transaction` ends in `abort and rollback or commit`, so its value
is the commit, not the block. Returning directly from `transaction` silently
yields `true` -- which reads as success and loses the record.

## A projection is part of the method's contract

The same table can be read several ways, and the projections here differ on
purpose: `recent_visits` selects the favicon because the sidebar renders one,
`search` does not because search rows never showed one, and
`top_pages_by_frecency` selects no id at all. Widening a projection is a
behaviour change -- suddenly the search rows have favicons -- so it is not
something to "tidy up" while converting a store to Domain objects.

The consequence is that a Domain object handed back by a repository may be
partially populated. Two rules keep that honest:

- **Require only what every projection can supply.** `Domain::Page` requires
  `uri` and nothing else; the id, the favicon and the timestamps are optional
  because one query or another genuinely lacks them.
- **Say what each query promises** in its docstring ("populated with uri,
  title, favicon and visit_count -- what the history sidebar renders"), and
  give the surprising ones a named test (`test_search_results_omit_the_favicon`)
  so the omission reads as a decision rather than an oversight.

## Constants shared with the Domain function the SQL approximates

`top_pages_by_frecency` ranks in SQL because it cannot run `Frecency.score`
over thousands of rows, then hands a shortlist to the real scorer. The
approximation's weights live in `Frecency` (`CANDIDATE_VISIT_WEIGHT`,
`SECONDS_PER_DAY`) and are interpolated into the `ORDER BY`:

```ruby
ORDER BY (visit_count * #{Frecency::CANDIDATE_VISIT_WEIGHT}) +
         (last_visited_at / #{Frecency::SECONDS_PER_DAY}) DESC
```

Interpolation is safe here and only here: these are integer constants owned by
Domain, not caller input. Everything a caller supplies stays a bound `?`.
