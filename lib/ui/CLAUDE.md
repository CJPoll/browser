# UI Components

GTK widgets. See `adrs/001-six-bucket-architecture.md` for the bucket rules;
this file records the conventions this directory follows.

> Several views in this directory still hold a manager (queue, history, tags).
> The six-bucket remediation plan reroutes them; the conventions below
> describe the target, which `download_list_view.rb` and
> `autocomplete_popover.rb` already follow.

## Data in, intent out

A UI Component receives the data it renders and a set of callbacks, and it
holds no manager, repository, adapter or WebKit object. It reports *what the
user wants*, not what should happen as a result -- the Framework
(`BrowserWindow`) binds each intent to a manager call.

```ruby
# UI: emits intent, then redraws from whatever the data source now returns
def intent_button(control, download)
  button.signal_connect("clicked") do
    @callbacks[:"on_#{control[:intent]}"]&.call(download.id)
    refresh
  end
end

# Framework: binds intent to the Manager
@download_list_view = DownloadListView.new(
  get_downloads: -> { @download_coordinator.get_all_downloads },
  on_pause: ->(id) { @download_handler.pause(id); update_download_badge }
)
```

Conventions:

- Constructor takes a single `callbacks` hash. Data sources are `get_*`
  lambdas; intents are `on_*` lambdas. Both are optional -- call them with
  `&.call` so a widget built without them still renders.
- A `get_*` callback bound by the Framework is *not* the same as holding a
  manager: the widget cannot name the manager, and a test supplies a plain
  array instead.
- The widget refreshes itself after emitting an intent. The Framework
  performs the call synchronously, so the next `get_*` already reflects it.

## Which controls appear is a domain decision

Mapping state to available actions is business logic, not layout. It lives in
Domain (`Domain::DownloadControls.for(download)` returns
`{intent:, label:, tooltip:}` descriptors) so it can be tested exhaustively
against the domain object's own predicates -- a test asserts that a button is
offered exactly when `can_pause?`/`can_resume?`/`can_cancel?` says so, which
stops the widget and the domain from drifting apart.

## Testing

**GTK signal emission does not reach Ruby handlers under minitest in this
environment.** `button.clicked` works in a plain `ruby -e` script but is
silently a no-op inside a `Minitest::Test` method -- the handler never runs
and no error is raised. Do not write tests that simulate clicks; they will
fail with an empty result and look like a logic bug.

Test instead:

- that `refresh` renders one row per item and replaces previous rows,
- that the expected controls appear (assert on `tooltip_text`, walking the
  widget tree),
- pure formatting helpers directly,
- that the component exposes no manager.

Behaviour behind a button belongs to the Domain module that chooses the
controls, the Manager that performs the action, and the handler that reaches
the framework -- all three are testable without GTK.
