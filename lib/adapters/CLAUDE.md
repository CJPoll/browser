# Adapters

Non-database side effects: external processes, HTTP, file stores, IPC, the
filesystem. See `adrs/001-six-bucket-architecture.md` for the bucket rules;
this file records the conventions this directory follows.

## Conventions

- **Namespace**: new adapters live under `module Adapters` in nested module
  form (`Adapters::FileSystem`). `FzfAdapter` is an older top-level constant;
  expect a mix during the remediation.
- **Narrow surface**: an adapter exposes only the operations its callers
  need. `Adapters::FileSystem` answers `exist?` and nothing else -- it is not
  a general-purpose wrapper around `File`.
- **Domain objects or primitives at the boundary**: adapters take and return
  Domain objects or plain values, never rows, widgets or WebKit objects.
- **No policy**: an adapter performs the effect; deciding *whether* to perform
  it belongs to a Manager. `FileSystem#exist?` reports what is on disk;
  `DownloadCoordinator` decides what to do about a collision.

## Shelling out: argv, never a shell string, and an injected runner

Every adapter that runs an external command (`Adapters::UriOpener`,
`Adapters::SystemNotifier`, `Adapters::ProcessLauncher`) follows the same
shape:

```ruby
SYSTEM_RUNNER = ->(*argv) { system(*argv) }

def initialize(runner: SYSTEM_RUNNER)
  @runner = runner
end

def open(target)
  !!@runner.call(COMMAND, target)
end
```

- **Arguments are passed separately.** `system("xdg-open", uri)` hands the URI
  to the process as data; `system("xdg-open #{uri}")` hands it to a shell.
  Most of these targets come from a web page, so the array form is not
  optional. Each adapter has a test asserting the argv it builds.
- **The runner is injected** so the test asserts the argv instead of opening
  the user's Spotify. A recorder of a few lines is enough; the default
  constant is what production uses.
- **`system` returns `nil` when the command is missing**, so coerce with `!!`
  before returning -- callers branch on true/false, not on nil.

## Running Ruby in another process: ship a script, pass arguments

`Adapters::PdfBookmarkWriter#add_bookmarks_later` starts a second Ruby process
so a crash inside a PDF library cannot take the browser down with it. The
version it replaced built that process's program by interpolating paths into a
heredoc:

```ruby
spawn('bundle', 'exec', 'ruby', '-e', <<~RUBY)
  markdown = File.read('#{temp_md.path}')          # a filename with a quote
  PdfBookmarkProcessor.add_bookmarks('#{pdf_path}', markdown)   # in it is code
RUBY
```

The argv rule above (arguments are data, never syntax) applies just as much
when the "shell" is Ruby. The fix is the same shape: a real script in `bin/`,
and the paths as `ARGV`.

- **The script is a repository file**, so a test can assert it exists at the
  path the adapter names -- a broken constant would otherwise only show up as
  a background process that silently does nothing.
- **`chdir` is the project, not `Dir.pwd`.** `bundle exec` needs the Gemfile,
  and the browser's working directory is wherever the desktop launched it.
- **The child owns the temp file it was given**: it reads the markdown and
  deletes it. The parent cannot know when the child is finished with it.

## HTTP: return the body, raise the failure

`Adapters::HttpFetcher` answers with the response body, or nil when the server
did not answer with success. It does **not** rescue network errors, because
its three callers disagree about what a failure means: a page that cannot be
fetched is warned about, a favicon that cannot be fetched is not, and an
oEmbed lookup that fails still leaves an entry worth saving. Swallowing the
exception here would take that decision away from the manager -- "no policy"
applies to error handling too.

The methods are named for what is being fetched rather than for HTTP verbs
(`fetch_page`, `fetch_api`, `fetch_asset`), because that is what carries the
differences: the browser User-Agent (sites serve different markup to scripts)
and the shorter timeout for an asset the entry can do without.

Parsing stays out. `fetch_api` returns the JSON body as a string;
`Domain::PageMetadata` reads it. The adapter moves bytes.

`fetch_document` is the exception that follows redirects, because a document
the user asked to read is worth chasing to where it moved. Redirect-following
belongs *here* rather than in a caller: it is still moving bytes, and a cap is
mandatory -- a server that redirects to itself would otherwise be followed
until the process dies. Answering nil past `MAX_REDIRECTS` lands in the same
"nothing to fetch" case every caller already handles.

## An adapter may compose another adapter

`Adapters::ContentFetcher` answers "the bytes behind this URL" for `file://`
as well as `http(s)://`, and reaches `Adapters::HttpFetcher` for the second.
That is one effect with two mechanisms, not two buckets: the manager above it
should not have to branch on scheme to decide which adapter to call.

The split that does matter is the one already stated above -- nil means "there
is nothing to fetch" (no such file, a server that refused, a scheme this
cannot read) and an exception means "the attempt failed". Only the manager
knows whether the latter deserves a warning.

## File-store adapters

`Adapters::SessionStore` and `Adapters::SettingsStore` are the JSON
counterparts of a repository: they read and write a hash and nothing else.
Two conventions hold them to that:

- **No policy, no defaults.** `SettingsStore#load` returns `{}` for a missing
  file; that dark mode defaults to off is `Managers::SettingsManager`'s rule.
  Likewise `SessionStore` does not know that a URI-less tab is not worth
  saving -- `Domain::SessionSnapshot` decides that before the hash arrives.
- **Failures are reported, not raised.** A save returns true/false and warns;
  the browser must not fail to close because `~/.local/share` is full.
  (Error-path `puts` became `warn` here -- diagnostics belong on stderr.)

Adapters that own a path default it (`DEFAULT_DIR`) and `mkdir_p` it in the
constructor, so Framework never has to know or pass one.

`Adapters::AutoTagRulesStore` is the read-only variant: it loads data that
ships with the browser (`config/auto_tag_rules.json`) rather than user state.
Same rules apply -- it returns the parsed data and nothing more, and a missing
or malformed file warns and reads as "no rules" rather than stopping the
browser from starting. Its test loads the *shipped* file as well as temporary
ones, because a rules file that no longer parses is a silent loss of a feature.

## Why adapters exist as a separate bucket from repositories

The split is load-bearing in tests: repositories are exercised against real
SQLite and never mocked, while adapters are mocked. Anything that would make a
unit test touch the network, spawn a process or depend on what is lying around
in `/tmp` belongs here so a test can substitute it.

## Testing

Adapters get thin tests of their own (they are mostly one-line wrappers over
something already tested by its own library) and are **mocked** everywhere
else. A mock is usually a few lines:

```ruby
class MockFileSystem
  def initialize(existing = []) = @existing = existing
  def exist?(path) = @existing.include?(path)
end
```

Where the real effect matters, cover it in an integration test that creates a
temporary directory (`Dir.mktmpdir`) rather than reaching into shared paths.
