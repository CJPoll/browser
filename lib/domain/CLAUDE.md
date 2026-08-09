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
| `Domain::QueueSort` | what order does the sidebar show the queue in? |
| `Domain::TagColor` | what colour is this tag drawn in? |
| `Domain::SessionSnapshot` | which tabs are worth restoring, and which one is selected? |
| `Domain::IpcMessage` | what is another instance asking this one to open? |
| `Domain::PageMetadata` | what does this page say about itself? |
| `Domain::AutoTagger` | which tags do the rules give this entry? |
| `Domain::MarkdownDocument` | what does this markdown document say about itself? |
| `Domain::MarkdownRenderer` | what page does this markdown document become? |
| `Domain::PopupDecision` | where does this popup belong -- window, tab, or nowhere? |
| `Domain::PermissionDecision` | may this site have what it is asking for? |
| `Domain::WebNotification` | what does this page's notification say, and who sent it? |
| `Domain::FileFilters` | what file types does this chooser offer? |
| `Domain::PdfOutline` | what bookmark tree do this document's headings make? |
| `Domain::PrintOutput` | where did this print job put its PDF, if it made one? |

## Presentation rules are Domain too

`Domain::QueueSort` and `Domain::TagColor` look like view code, and they are
called from `lib/ui/` -- which is allowed, UI may call Domain. They live here
because they are deterministic decisions with no IO, and because more than one
widget needs the same answer: the queue row and the sidebar's filter bar must
agree on a tag's colour, and they now do so without either widget knowing the
other exists.

The line to hold is *layout stays in the widget*. `TagColor.rgb` returns
`[r, g, b]`, not a `Gdk::RGBA` -- the moment Domain names a GTK type it has
stopped being a rule and started being a widget.

## The wire format is Domain; reading the file is not

`Domain::IpcMessage` owns `parse`/`serialize` for the file two browser
instances talk through, and `Domain::SessionSnapshot` owns `from_h`/`to_h` for
the session file. The adapter underneath does nothing but move bytes.

Two things follow from splitting it there:

- The parser must **never raise**, because the file it reads can be
  half-written. A truncated message parses to one with a zero timestamp, which
  no watermark will accept -- an invalid input becomes a value that is
  harmless downstream, rather than an exception the Framework has to catch.
- Round-tripping is a one-line test (`assert_equal message, parse(serialize)`)
  with no filesystem in it, which is what makes covering the odd shapes --
  a request with no URL, a session with no tabs -- cheap enough to bother.

This is the same rule as "repositories map rows to Domain objects": the
storage bucket handles bytes, Domain handles meaning. The difference is only
that `to_h`/`from_h` sit on the Domain object here, because a JSON file (unlike
a table) has no schema to keep them honest.

## Fetching is an Adapter's job; making sense of the bytes is Domain's

`Domain::PageMetadata` takes HTML (or a JSON body) that somebody else fetched
and answers what the page's title is, where its favicon lives, and what the
embedded JSON-LD says about a video. Splitting there is what makes the odd
cases cheap to cover -- a Latin-1 title, a page whose only JSON-LD is
malformed, an `uploadDate` of `"last tuesday"` -- none of which need a network
stub.

Two conventions came out of it:

- **Never return nil where the caller would only have to invent a fallback.**
  `favicon_url` falls back to `/favicon.ico` itself, because "there is no
  icon link" and "the icon is at the conventional path" are the same decision,
  and it was previously spelled out at the call site.
- **Raise on input that is simply unusable**, and let the caller decide
  whether that deserves a warning. `youtube_metadata_from_oembed` lets
  `JSON::ParserError` out (the manager warns and carries on) but returns nil
  for a well-formed response that names neither title nor channel. Malformed
  is an accident; empty is an answer.

## Payloads the browser ships are Domain, not files

`Domain::ArticleExtractorJS`, `Domain::MarkdownStyles` and
`Domain::MermaidScript` are nothing but constant strings behind a method:
JavaScript to run in a page, CSS to wrap a document in. They are Domain
because producing them reads nothing -- same call, same bytes -- and they are
not files on disk because loading them would put an adapter and an IO failure
mode in the path of something that cannot vary.

Two conventions keep them honest:

- **The payload is data; assembling the page is a function.** `MarkdownStyles`
  answers with CSS and knows nothing about where it is inserted;
  `Domain::MarkdownRenderer` builds the document around it. Otherwise every
  payload grows a second job and stops being copy-pasteable.
- **Move them verbatim, and prove it.** Relocating ~500 lines of CSS by hand
  invites a lost blank line nobody notices until a PDF prints wrong. Extract
  the heredocs with a script and assert the old and new methods return
  identical strings before deleting the original -- a one-off comparison run
  is cheaper than reviewing 500 lines twice.

The same check is worth running on the *rendered* output: comparing the old
and new pipeline's HTML byte for byte across a handful of documents (plain,
mermaid, page break, no heading) is what turns "I think this is a pure move"
into a fact.

`Domain::VideoPopoutStyles` adds the third convention: **the payload that gets
embedded in another payload owns its own escaping.** The CSS travels inside a
JavaScript template literal, so `injection_script` escapes backticks -- and
the test asserts that exactly two unescaped backticks survive, which is the
kind of thing nobody notices breaking until a stylesheet with a backtick in it
turns the rest of the script into syntax errors.

## Plan the work, let the adapter do it

`Domain::PdfOutline` shows the shape to reach for when a pure computation is
interrupted by an unavoidable effect in the middle:

```
headings(markdown)  ->  [Heading]     # text and level, pure
   ...the adapter searches the PDF for each heading's page...
plan(headings)      ->  [Bookmark]    # nesting resolved, pure
```

Rather than hand the adapter a tree to walk (which would put "what nests under
what" back in the effect), `plan` returns a **flat list where each item names
its parent by index**. The adapter creates them in order and looks each parent
up in what it has already created -- five lines, no recursion, no rules.

The same split is why the outline's one genuine bug is *visible*: a document
that skips a heading level and then repeats the deeper one leaves a hole in
the parent stack, and `plan` raises `MalformedHeadingLevels` where the
original raised `NoMethodError` on nil three layers down. Preserved rather than
fixed (the plan's rule), but now it is a named error with a test instead of a
crash.

## Rules that change often are data, not code

The auto-tagging rules -- which channels and keywords earn which tag -- live in
`config/auto_tag_rules.json` and reach `Domain::AutoTagger.from_rules` through
`Adapters::AutoTagRulesStore`. Domain owns *how* a rule matches; the file owns
*which* rules exist.

`from_rules` accepts string or symbol keys, so a test writes a literal and
production passes parsed JSON through the same constructor. It uses `fetch`
for the required fields, so a rule missing its `fields` raises at load rather
than silently never matching.

## A third-party library is Domain if the library is a pure transform

`Domain::MarkdownRenderer` calls Redcarpet. That is allowed for the same
reason `PageMetadata` may call `JSON.parse`: the gem turns text into text and
touches nothing else. What decides the bucket is the *effect*, not whether the
code is ours.

Two things to watch when a gem lands in Domain:

- **Do not share a stateful instance.** Redcarpet's renderer objects carry
  state between calls, so `markdown_engine` builds a fresh one per render.
  A memoised instance would make a document's HTML depend on what was
  rendered before it -- which is exactly the purity claim being made.
- **Keep the options next to the transform.** The dialect (tables, footnotes,
  autolinks, heading anchors) is part of what the browser *means* by markdown,
  so it is a Domain constant, and a test asserts each one still renders.

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

## When the caller has to act, return a decision *object*

A symbol is enough when the caller already holds everything it needs
(`:home_path` above). When acting on the answer also needs *data derived while
deciding*, return a value object carrying both, so the Framework never
re-derives anything:

```ruby
decision = Domain::PopupDecision.for(url: destination_url, allowed: allowed?)
# => action: :prompt, url: 'https://ads.example.com/x', host: 'ads.example.com'
```

`BrowserWindow` then reads as a `case` over `decision.action` where every
branch is a widget operation. The host it names in the bar was worked out by
Domain, not parsed again at the call site -- which is how the old block came
to have `URI.parse` inside a WebKit signal handler.

Two conventions make these objects worth their weight:

- **The action vocabulary is small and shared.** `allow` / `prompt` / `ignore`
  covers the camera, notifications *and* certificate exceptions, so one
  `PermissionDecision` serves three flows and the Framework's three `case`
  statements have the same shape. Resist a fourth action until a caller
  genuinely needs to do a fourth thing.
- **Unusable input is a decision, not an exception.** A popup with no host
  gets `:block` rather than `:prompt` because a bar would have nothing to
  name; a permission request from `about:blank` gets `:ignore` because there
  is nothing to record a grant against. The distinction that used to be an
  `if host` buried in the Framework becomes a named action with a test.

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
