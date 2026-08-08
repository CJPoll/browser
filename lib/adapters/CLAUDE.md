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
