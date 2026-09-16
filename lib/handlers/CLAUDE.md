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

## A page API the browser provides itself

`PasskeyHandler` gives pages a `navigator.credentials` that WebKitGTK lacks.
The shape, for the next feature that has to hand a page an API:

- **The script is Domain** (`Domain::PasskeyShimJs`). The handler injects it
  as a `UserScript` at document start, top frame only, on the tab's own
  `UserContentManager` (`Tab` creates one per webview so handlers are scoped).
- **One message in, one statement out.** The shim posts a JSON request with
  an id; the handler answers by evaluating
  `window.__toyPasskey.complete(<json>)`. `Domain::PasskeyRequest` and
  `Domain::PasskeyResponse` own both wire formats, and
  `PasskeyShimJs.completion_call` escapes U+2028/9 so the JSON is also valid
  JavaScript.
- **Trust nothing the page says about itself.** The origin is
  `Domain::WebOrigin.from_url(webview.uri)`; the message is data. Top-frame
  injection is what makes the webview's URI the right origin.
- **Reading a script message** needs the JavaScriptCore typelib, loaded by
  `lib/javascript_core.rb`; `result.js_value.to_s` is then the string.
- **Per-webview pending state is Framework state**, keyed by `object_id` like
  the markdown guard. A second request while a bar is up is refused with
  `NotAllowedError` without asking the manager, and the entry is cleared on
  delivery rather than by any guess about the widget's fate.
- `handle_message` is public and tested with a fake webview and a spy
  manager; `attach` is the only method that touches WebKit.

## Evaluate and read back, in an isolated world -- no message handler needed

`LoginFillHandler` also gives a page behaviour it lacks (filling a login form),
but unlike `PasskeyHandler` it injects no user script and registers no message
handler. It only *evaluates* JavaScript and reads the completion value:

- **The scripts are Domain** (`Domain::LoginFormJs`): a probe that reports
  whether there is a fillable form, and a fill call that sets the fields. The
  handler evaluates the probe, hands the JSON to the manager, and -- once the
  user confirms -- evaluates the fill call the manager's credential produced.
- **Run them in an isolated world** (`evaluate_javascript(script, -1,
  WORLD_NAME, nil, nil)`): the same DOM, separate JS globals, so the page
  cannot observe the functions and `JSON`/`Event`/`HTMLInputElement.prototype`
  are the pristine ones. `WORLD_NAME` is a Domain constant so the probe and
  fill agree, and a test asserts the world passed for both scripts.
- **Reading the completion value** needs the JavaScriptCore typelib
  (`lib/javascript_core.rb`); `source.evaluate_javascript_finish(result).to_s`
  is then the JSON string.
- **Trust nothing the page says about itself.** The origin is
  `Domain::WebOrigin.from_url(webview.uri)`, taken again at confirm time so a
  navigation between offering and filling is caught; the probe's own `origin`
  field is informational and never used for policy.
- **Fire-and-forget with a defensive rescue.** If the page navigated the
  completion block simply never runs; an error in the block releases the tab's
  pending slot and logs only the exception class -- never the script or the
  credential, because the scripts throw nothing of their own.
- **Per-webview pending state**, keyed by `object_id` like the passkey and
  markdown handlers, released on cancel/notice/report/error. `handle_probe`
  and `handle_report` are public and tested with a fake webview and a spy
  manager; `fill_current` and `evaluate` are the only WebKit contact.

## Testing

Handlers are tested with small hand-written fakes for the WebKit objects (a
module providing `signal_connect`/`emit` is enough) and a spy Manager. Assert
on which Manager calls were made -- the behaviour behind those calls is
covered at the manager and domain layers. Tests live in `test/handlers/`.
