# UI Components

GTK widgets. See `adrs/001-six-bucket-architecture.md` for the bucket rules;
this file records the conventions this directory follows.

No file in this directory holds a manager, repository or adapter. The
conventions below are what keeps that true.

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
- An intent callback may **return** something. `TagEditDialog`'s
  `on_assign_tag` hands back the manager's result symbol
  (`:assigned` / `:already_assigned` / `:invalid_entry`) because the dialog has
  to react differently to each. That is still data in, intent out -- the
  dialog says what the user wants and is told what came of it, without naming
  who did it.
- A lookup the widget needs to interpret its own state is a `find_*` callback
  (`find_tag_by_name`, `find_tag_by_id`). The queue view keeps *which* tags are
  filtered on -- that is view state -- but it cannot turn an id into a name on
  its own.

## Keep view state, push policy out

`QueueListView` owns the set of ticked filter tags and the chosen sort mode:
those are the user's place in the UI and belong to the widget. What those
choices *mean* does not.

- "No tags ticked" means every entry, and that is a queue rule, so
  `Managers::QueueManager#entries_for_filter` decides it. The widget just
  passes the ids it is holding.
- The three sort orders are `Domain::QueueSort`, exhaustively tested without a
  widget in sight.

The test for the split: if the answer would be the same with no GTK in the
process, it does not belong in this directory.

## A dialog that differs only in its data takes the data

Three places asked the user for a file -- Ctrl+O, the PDF bookmark chooser and
an `<input type="file">` on a page -- with forty lines of identical dialog
construction each. What actually differed was the title, the filters, whether
several files may be picked and whether images preview, so `FileChooser` takes
those four and nothing else:

```ruby
FileChooser.new(
  parent: self, title: "Select File",
  filters: [request.mime_types_filter, *Domain::FileFilters.for_upload(request.mime_types)],
  select_multiple: request.select_multiple?, preview: true
).choose   # => Array<String>, empty when the user cancelled
```

- **Which types a chooser offers is a rule, so it is Domain**
  (`Domain::FileFilters`), and the widget turns descriptors into
  `Gtk::FileFilter` objects. That is what makes "an image filter appears only
  when the page asked for images" testable.
- **A descriptor list accepts a ready-made GTK object too.** WebKit hands over
  a `Gtk::FileFilter` for the element's `accept` attribute; `gtk_filter`
  passes anything that is already one straight through rather than forcing the
  Framework to invent a descriptor for it.
- **One return shape.** `choose` always answers with an array, so "cancelled"
  and "picked nothing" are the same empty result -- which is what all three
  callers did with them anyway.
- **Split the dialog from the running of it.** `build_dialog` is public, so a
  test can assert the filters, the title and the preview widget; only `choose`
  needs a user, and it is three lines.

## A widget that cannot shrink sets the sidebar's width

`Sidebar#minimum_content_width` is GTK's minimum for the whole widget tree, and
it is what the sidebar opens at. Every label in a sidebar row therefore has to
be able to give up space -- one that cannot puts a floor under the width the
user sees. A tag name of forty characters held the sidebar at 433px until the
pill label got `ellipsize = :end`; with it, the same sidebar opens at 257px and
the floor is the chrome that genuinely cannot shrink (the favicon, the remove
button, the header's filter and sort buttons).

So: anything rendered from user data in a row -- title, URL, tag name -- gets
an `ellipsize`. Test it by asserting the row's `preferred_width` minimum is the
same for short and long content.

## Do not let a widget reach through another widget

`Sidebar` used to call `queue_list_view.queue_manager.find_tag_by_name(...)`
to translate a filter pill back into a tag id. Two rules broken with one
expression -- a UI component naming a manager, and a widget reading another
widget's collaborator.

The fix is to ask the owning widget for the *operation*, not its guts:
`queue_list_view.remove_filter_tag_by_name(tag_name)`. When a widget needs
another widget's state, the method it wants is almost always a verb.

The same rule covers `instance_variable_get`, which is all over this
directory. GTK rows carry no user data, so a view stashes the domain object on
each row it builds and reads it back later -- that is the idiom and it is
fine, *inside the class that created the row*. It stops being fine the moment
somebody else does it: `BrowserWindow` used to walk
`sidebar.queue_list_widget.children` reading `@queue_entry` off each row to
move the selected entry. Two verbs replaced it -- `selected_entry` and
`select_entry(id)` on `QueueListView`, delegated by `Sidebar` -- and the
private `entry_for(row)` is where the stash is now read.

Rule of thumb: `instance_variable_get(:@x)` is acceptable only on a widget
`self` created, and only from a method that names what the caller wanted.

## A list of lists takes section descriptors

`SitePermissionsWindow` shows four differently-sourced lists. Rather than four
`create_*_section` / `refresh_*_list` method pairs -- which is how it hard-coded
four managers -- it takes an array of descriptors and renders whatever it is
given:

```ruby
SitePermissionsWindow.new(
  sections: [
    { title:, description:, empty_text:,
      get_permissions: -> { @site_permission_manager.popup_permissions },
      on_remove: ->(permission) { ... },
      row_label: ->(permission) { ... } }   # optional; defaults to the host
  ],
  parent_window: self
)
```

Two things fall out. Adding a section is a Framework change only -- the widget
does not grow a method. And a test builds a section from a plain array, so
every rendering path is exercised without a manager in sight.

The Framework method that builds the descriptors (`site_permission_sections`)
is worth keeping separate from the one that opens the window: it is the only
place that knows both the manager and the copy.

## Which controls appear is a domain decision

Mapping state to available actions is business logic, not layout. It lives in
Domain (`Domain::DownloadControls.for(download)` returns
`{intent:, label:, tooltip:}` descriptors) so it can be tested exhaustively
against the domain object's own predicates -- a test asserts that a button is
offered exactly when `can_pause?`/`can_resume?`/`can_cancel?` says so, which
stops the widget and the domain from drifting apart.

## One bar, two renders

`LoginFillBar` is a single widget that renders either a prompt (a login to
fill) or a notice (why nothing was), because both occupy the same spot and the
Framework should not care which it is showing.

- **The buttons differ, so they are packed at render time, not in the
  constructor.** `show_prompt` packs Fill + Cancel (and a `ComboBoxText` only
  when `prompt.choice_needed?`); `show_notice` never packs the Fill button and
  relabels the remaining one "Dismiss". A test walks the tree and asserts the
  button set for each.
- **Data in, intent out, no secret in.** Its inputs are a `LoginFillPrompt` or
  a `LoginFillNotice` -- neither carries a password -- and it emits `on_fill`
  with the chosen index or `on_cancel`. It holds no manager and no webview; a
  test pins that no ivar name matches `manager`/`webview`.
- **User data is escaped.** The message carries the item's title and username,
  so the label uses `CGI.escapeHTML` inside Pango markup, exactly as
  `PasskeyPromptBar` does.

## Testing

**GTK signal emission does not reach Ruby handlers under `rake test`.**
`button.clicked` works in a plain `ruby -e` script but is silently a no-op
inside a `Minitest::Test` method -- the handler never runs and no error is
raised. Do not write `_test.rb` tests that simulate clicks; they will fail
with an empty result and look like a logic bug.

The cause (found while writing the passkey page check): `minitest/autorun`
runs the suite from an `at_exit` hook, and once the Ruby VM is exiting
ruby-gnome no longer dispatches GObject signal closures -- `clicked`,
`load-changed`, `script-message-received`, `notify::title` -- to Ruby. GLib
timeouts still fire, so a `Gtk.main` inside a test returns only when its
deadline does. The very same test passes when run through an explicit
`exit Minitest.run(ARGV)`. Until the suite runs that way, a test that needs
real signals is a standalone check outside the `*_test.rb` glob that runs
itself; `test/integration/passkey_page_flow_check.rb` is the model.

Test instead:

- that `refresh` renders one row per item and replaces previous rows,
- that the expected controls appear (assert on `tooltip_text`, walking the
  widget tree),
- pure formatting helpers directly,
- that the component exposes no manager.

Behaviour behind a button belongs to the Domain module that chooses the
controls, the Manager that performs the action, and the handler that reaches
the framework -- all three are testable without GTK.

Where a button does have widget-level behaviour worth pinning -- "emit the
intent, then redraw this section from its data source" -- make that a **public
method** and let the signal handler be a one-line call to it:

```ruby
def remove_permission(section, permission)
  section[:on_remove]&.call(permission)
  refresh_section(section)
end

remove_button.signal_connect("clicked") { remove_permission(section, permission) }
```

The test calls `remove_permission` directly and asserts the row disappeared.
Only the one-line `signal_connect` stays untested, which is as close to the
GTK boundary as this environment lets us get.

This is not only about buttons. Setting `search_entry.text = "found"` does not
emit `search-changed` under minitest either, so a handler that reads the
widget back (`@search_query = @search_entry.text.strip`) is unreachable from a
test *and* only works when the text came from the keyboard.
`HistoryListView#search(query)` takes the query as an argument and the signal
handler is `search(@search_entry.text)`. Rule of thumb: **the handler extracts,
the method decides** -- anything a signal handler pulls out of a widget should
become that method's parameter.
