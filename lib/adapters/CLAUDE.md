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
