# Domain

Side-effect-free business logic. See `adrs/001-six-bucket-architecture.md` for
the bucket rules; this file records the conventions this directory follows.

## Conventions

- **Purity**: given the same inputs, a Domain method always returns the same
  output. No IO, no SQL, no GTK, no processes, no HTTP, no clock reads, no
  randomness. Domain must not reference a Manager, Repository, Adapter,
  Framework class, or UI Component.
- **Immutability**: value objects expose readers only. State changes return a
  new instance -- see `Download#with`, which every `mark_*` transition is
  built on.
- **No SQL awareness**: repositories map rows to Domain objects in a private
  `build_*`/`from_row` method on the *repository* side. Domain objects never
  know about columns or tables.
- **Namespacing**: current Domain files are top-level constants (`Download`,
  `Frecency`). The remediation plan introduces `Domain::`-namespaced modules;
  expect a mix during the transition.

## The clock is a required parameter

Domain never reads the clock. The current time is passed in as a **required**
argument -- not a defaulted one, because `now = Time.now` is still a clock
read and still makes tests nondeterministic.

```ruby
# lib/domain/download.rb
def mark_completed(now:)
  with(state: :completed, completed_at: now)
end

# Required keyword, so it cannot silently fall back to the real clock:
def initialize(url:, destination:, created_at:, ...)
```

The calling **Manager** owns the clock and is where the default lives (see
`lib/managers/CLAUDE.md`). Repositories may read the clock directly; they are
a side-effect bucket (e.g. `DownloadRepository#delete_older_than`).

Positional (`Frecency.score(count, last_visited_at, now)`) and keyword
(`Download#mark_completed(now:)`) forms are both in use -- prefer keyword for
methods that already take other arguments.

## Testing

Domain tests are the exhaustive layer of the pyramid: no mocks, no fixtures,
no setup beyond constructing values. Tests live in `test/domain/`.

Because time is injected, assert on exact timestamps rather than
`refute_nil`. Use frozen constants and a builder for the common case:

```ruby
CREATED_AT = Time.at(1_700_000_000).freeze
NOW = Time.at(1_700_003_600).freeze

def build_download(**overrides)
  Download.new(**{ url: '...', destination: '...', created_at: CREATED_AT }.merge(overrides))
end

assert_equal NOW, build_download.mark_completed(now: NOW).completed_at
```

Also assert that the injection point exists -- a test that omitting `now:`
raises `ArgumentError` is what stops a default from creeping back in.
