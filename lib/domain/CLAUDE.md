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
- **Namespacing**: new Domain code is `Domain::`-namespaced, written in nested
  module form (`module Domain` / `module UrlMatcher`) so the namespace is
  always defined regardless of require order. `Download` and `Frecency` are
  older top-level constants; expect a mix during the transition.
- **Requires**: each Domain file requires its own stdlib dependencies (`uri`,
  `cgi`) and is required directly by its callers via `require_relative`. There
  is no autoloader, so a caller that names `Domain::X` must require
  `lib/domain/x`.

## Shared modules

Before writing a URL or tag helper, check whether one already exists -- these
were extracted precisely because the same logic had been written twice:

| Module | Answers |
| --- | --- |
| `Domain::UrlMatcher` | do these two URLs refer to the same page? |
| `Domain::UrlHost` | what host/authority does this URL name? |
| `Domain::UrlClassifier` | did the user type a URL, a path, or a search? |
| `Domain::ExternalSchemes` | should another application handle this URL? |
| `Domain::OauthPopup` | does this URL need a real popup window? |
| `Domain::TagName` | what is the canonical form of this tag name? |
| `Domain::Frecency` | how relevant is this history entry? |
| `Domain::QueueTraversal` | which queue entry comes next from here? |

## Return a decision, not a side effect

When the pure part of a computation ends where the impure part begins, return
the decision and let the caller act on it. `UrlClassifier.classify` returns
`:home_path` rather than a `file://` URL because expanding `~` reads the
environment -- so the handler does the expansion and Domain keeps the
heuristics:

```ruby
case Domain::UrlClassifier.classify(text)
when :home_path then "file://#{File.expand_path(text)}"
...
```

This keeps the branching logic testable without stubbing `ENV`.

## Preserved warts are pinned by tests

Logic extracted during the remediation is moved verbatim, warts included (for
example `UrlMatcher` ignores the port, and `ExternalSchemes` cannot recognise
`mailto:` because it splits on `://`). Give each one a named test that asserts
the current behaviour and a comment saying it is a known wart. A wart with a
test is a documented decision; a wart without one gets "fixed" by the next
reader and silently changes behaviour.

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

## Value objects: `with`, `to_h`, and value equality

The queue and tag objects follow the shape `Download` and `HostPermission`
established, and it is worth copying wholesale:

- required arguments raise `ArgumentError` with the attribute name;
- `freeze` at the end of `initialize`;
- `to_h` is the single definition of "every attribute", and `==`/`eql?`/`hash`
  are all written in terms of it, so adding an attribute cannot leave equality
  behind;
- `with(**overrides)` returns a copy (`to_h.merge(overrides)`), which is how a
  repository stamps an id and position onto an entry it just inserted;
- `==` checks the class, so an object is never equal to a lookalike hash --
  worth a test, because that is exactly the bug a hash-to-object migration
  leaves behind.

Give the object the derived reader the callers keep re-deriving.
`QueueEntry#display_title` (`title || url`) replaced four copies of
`entry['title'] || entry['url']` across the window and the sidebar.

## Predicates about "what may this subdomain accept" live on the Domain object

`Domain::QueueEntry.queueable_url?` answers "will the queue take this URL?"
(http/https only). It sits with `QueueEntry` rather than in a URL module
because it is the *queue's* rule, not a fact about URLs -- a `file://` link is
perfectly valid, just not queueable. The manager calls it before constructing
anything, so the rule is testable without a database and cannot be bypassed by
a second caller.
