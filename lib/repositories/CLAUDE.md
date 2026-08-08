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
