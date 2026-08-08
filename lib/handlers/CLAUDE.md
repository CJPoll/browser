# Handlers

Framework: the code that speaks GTK and WebKit. See
`adrs/001-six-bucket-architecture.md` for the bucket rules; this file records
the conventions this directory follows.

## Conventions

- A handler translates framework events into Manager calls and reports the
  results through `on_*` callbacks supplied by its owner. It holds no SQL, no
  persistence and no business rules.
- Handlers **must not** call a Repository or an Adapter directly; go through a
  Manager.
- The framework objects (WebKit downloads, GTK events) stop here. Domain
  objects go out; WebKit objects never reach a UI Component or a Manager.

## Managers arrive as keywords, callbacks as the hash

`MouseHandler` and `NavigationHandler` take their callback hash positionally
and their collaborators as keywords with a production default:

```ruby
def initialize(callbacks, external_opener: Managers::ExternalOpener.new)
```

The callback hash is what the owner wires up (which tab is current, how to
open a new one); a manager is a collaborator the handler needs regardless of
who owns it. Keeping them apart means a new collaborator does not become
another key every caller has to remember to pass, and a test can substitute
just the one it cares about.

## Signals you provoke yourself

WebKit reports a cancelled transfer as a *failure*, so any handler that
cancels a download on purpose will receive a `failed` signal for it moments
later. Left alone, that signal overwrites the state just recorded -- a pause
becomes a failure.

`DownloadHandler` keeps a set of IDs it stopped deliberately and drops the
first failure that arrives for each:

```ruby
def stop_transfer(download_id)
  @intentionally_stopped << download_id
  @webkit_downloads.delete(download_id)&.cancel
end

def handle_failed(download_id, error)
  return if @intentionally_stopped.delete?(download_id)
  ...
end
```

Record the state *first*, then stop the transfer: the flag must be set before
the signal can arrive.

## Adopting a record for a transfer you start

WebKit's `download-started` fires for downloads the browser initiates itself,
so a resume would otherwise create a second database row for the same file.
`DownloadHandler#resume` parks the existing record and the next
`download-started` claims it:

- the window is exactly **one** event, and
- the URL must match,

so an unrelated download starting in between cannot steal the record. Any
scheme that leaves the flag set indefinitely will eventually attach the wrong
transfer.

## Guarding against the signals your own load provokes

`MarkdownHandler` renders a `.md` URL itself and calls `load_html`, which
makes WebKit ask `decide-policy` about the *same* URL again. Without a guard
the handler would render it a second time -- refetching the document on every
pass.

The guard is a set of URLs currently being loaded, and it is Framework state:
it exists because of how WebKit re-enters, and the manager it delegates to
does not know the signal exists. Clearing it has to wait for the main loop, so
the scheduler is injected the same way the metadata worker's is:

```ruby
MAIN_THREAD_SCHEDULER = lambda do |&block|
  GLib::Idle.add { block.call; false }
end

def initialize(manager: Managers::MarkdownManager.new, scheduler: MAIN_THREAD_SCHEDULER)
```

A test then holds the scheduled block and asserts both halves -- that a second
navigation while the load is in flight is ignored, and that running the
scheduled work lets the next one through. Same seam as
`Managers::QueueMetadataWorker`; see `lib/managers/CLAUDE.md`.

This is the general shape for "signals you provoke yourself" (above): record
the guard before the call that triggers the signal, and clear it on the main
loop rather than inline.

## Testing

Handlers are tested with small hand-written fakes for the WebKit objects (a
module providing `signal_connect`/`emit` is enough) and a spy Manager. Assert
on which Manager calls were made -- the behaviour behind those calls is
covered at the manager and domain layers. Tests live in `test/handlers/`.
