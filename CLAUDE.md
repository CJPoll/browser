# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A toy web browser built with Ruby, GTK3, and WebKitGTK. Features include browsing history, read/watch/do queue, persistent cookies, Picture-in-Picture (in development), zen mode, and keyboard shortcuts.

## Running the Browser

```bash
./run
```

Or directly with bundle exec:
```bash
bundle exec ruby simple_browser.rb [URL]
```

The `run` script ensures asdf environment is available (needed for launching from desktop environment). Optional URL argument opens that URL directly.

The browser will start with a 1200x768 window. If no URL provided, it restores the previous session or opens example.com.

## Architecture

**Bucket rules**: Every class belongs to exactly one of six buckets --
Framework, UI Components, Repositories, Adapters, Domain, Managers -- with
constrained call directions between them. See
`adrs/001-six-bucket-architecture.md` for the definition, the allowed-calls
matrix, and the target bucket assignments for existing code. Highlights: UI
must not call Managers/Repositories/Adapters (bubble events up via
callbacks); Framework must not call Repositories/Adapters (go through a
Manager); all SQL lives in `lib/repositories/`; Domain is pure (no IO, no
clock reads).

### Core Components

**BrowserApplication** (`lib/browser_application.rb`):
- GTK Application subclass managing app lifecycle
- Single-instance enforcement via GTK ApplicationFlags
- IPC monitoring (500ms timer checking `~/.local/share/toy-browser/pending-url`)
- Signal handlers: activate, command-line, open
- Window management: creates and presents BrowserWindow

**BrowserWindow** (`lib/browser_window.rb`):
- Main window orchestrator (thin layer coordinating components)
- Owns component instances: Toolbar, Sidebar, Handlers, Managers
- Sets up GTK signal handlers and callbacks
- Public API for tab/queue/navigation operations
- No business logic (delegates to components)

**Tab** (`lib/tab.rb`):
- Individual browser tab with WebView
- WebKit experimental features enabled (FileSystemAccess, StorageAPI, etc.)
- Manages tab-specific state (title, URI, favicon)

**UI Components** (`lib/ui/`):
- `toolbar.rb` - Top toolbar with navigation controls and URL entry
- `sidebar.rb` - Left sidebar container (tabs/history/queue mode switching)
- `tab_list_view.rb` - Tabs list in sidebar
- `history_list_view.rb` - History list in sidebar
- `queue_list_view.rb` - Queue list in sidebar with drag-and-drop reordering

**Handlers** (`lib/handlers/`):
- `keyboard_handler.rb` - Keyboard shortcut routing (25+ shortcuts)
- `mouse_handler.rb` - Mouse button navigation (back/forward buttons)
- `navigation_handler.rb` - URL parsing and navigation logic

**Managers** (`lib/managers/`):
- `web_context_manager.rb` - WebKit context setup (stateless utility)
- `settings_manager.rb` - Persistent settings (dark mode, etc.)
- `session_manager.rb` - Save/restore window sessions
- `favicon_manager.rb` - Favicon fetching with debouncing
- `queue_metadata_worker.rb` - Background metadata fetching for queue

**History** (`lib/repositories/` + `lib/managers/`):
- `history_repository.rb` - the `sites`/`pages`/`visits` tables in `history.db`
- `history_manager.rb` - visit recording (owns the clock and the
  duplicate-arrival policy), search and autocomplete candidates

**Queue** (`lib/repositories/` + `lib/managers/`):
- `queue_database.rb` - shared `queue.db` connection, schema and migrations
- `queue_repository.rb` / `tag_repository.rb` - the two tables behind it
- `queue_manager.rb` - queue CRUD, metadata and tags (the subdomain API)
- `queue_navigation_manager.rb` - next/previous/remove-and-advance

**External Components** (project root):
- `video_popout_window.rb` - Picture-in-Picture floating window (WIP)
- `run` - Wrapper script for asdf environment setup

**Migration History**:
- **Before Nov 2025**: Monolithic `simple_browser.rb` (~2200 lines)
- **Phase 1-5 (Nov 2025)**: Extracted 14 classes into lib/ subdirectories
- **Phase 6 (Nov 2025)**: Final refactoring - BrowserWindow and BrowserApplication extraction
- **Result**: ~60 lines in simple_browser.rb entry point, 15 focused classes averaging ~150 lines each

### Single-Instance Behavior

The browser uses GTK Application with `HANDLES_COMMAND_LINE` and `HANDLES_OPEN` flags for single-instance behavior:

- **First launch**: Creates window, handles URL argument if provided
- **Subsequent launches**: Prevents duplicate processes, passes URLs to existing instance via IPC
- **IPC mechanism**: File-based (`~/.local/share/toy-browser/pending-url`)
  - Second instance writes URL + timestamp to IPC file
  - First instance monitors file every 500ms via GLib::Timeout
  - URLs open as new tabs in existing window
- **Thread safety**: All UI updates via `GLib::Idle.add` from background threads

### Default Browser Integration

The browser can be set as the system's default browser:

- **Desktop file**: `~/.local/share/applications/ruby-browser.desktop`
- **Exec line**: Calls `run` script with `%u` (URL) parameter
- **xdg-open**: Clicking links in terminal or other apps opens in browser
- **IPC integration**: Links clicked while browser is running open as tabs, not new windows

### Data Storage

- **History DB**: `~/.local/share/toy-browser/history.db`
- **Queue DB**: `~/.local/share/toy-browser/queue.db`
- **Cookies**: `~/.local/share/toy-browser/cookies.sqlite`
- **Cache**: `~/.cache/toy-browser/`

All directories are created automatically on first run.

### WebKit Integration

The browser uses WebKit2GTK's web context and user content manager:

- **Web Context**: Manages persistent storage (cookies, cache)
- **User Content Manager**: Handles JavaScript injection for custom features
- **JavaScript Injection**: Scripts injected on page load via `run_javascript()` since UserScript injection doesn't work reliably

### Favicon Handling

**Debouncing Strategy:**
- Sites like YouTube provide multiple favicon sizes (5+ variants)
- Without debouncing, each size triggers a separate database write
- **Solution**: Hybrid debouncing approach
  - Track largest favicon seen for each URL
  - 300ms timer resets with each new favicon
  - After 300ms silence, save only the largest favicon
  - Reduces 8+ DB writes to 1 per page load

**Implementation:**
- Uses `GLib::Timeout.add(300)` for debounce timer
- Stores candidates in `@favicon_candidates` hash (url → {size, surface})
- Cancels previous timer when new larger favicon arrives
- Converts Cairo surface to PNG for storage

### Sidebar Behavior

- **Width**: Always starts at 15% of window width
- **Not persisted**: Width resets on each window creation
- **User adjustable**: Can be resized during session, but doesn't save
- **Single map event**: Sidebar width only set on first window map to prevent resizing when presenting window

### WebKit Experimental Features

Modern web apps (like 1Password) require experimental WebKit features that are disabled by default. The browser enables these in Tab initialization:

**Currently Enabled Features:**
- `StorageAPI` - Provides `navigator.storage` API
- `FileSystemAccess` - File System Access API for OPFS
- `FileSystemWritableStream` - WritableStream API for file operations
- `AccessHandle` - `createSyncAccessHandle()` for synchronous file I/O in workers

**How Features Are Enabled:**
```ruby
# Get list of experimental features (class method, not instance method)
experimental_features = WebKit2Gtk::Settings.experimental_features

# FeatureList is not an Array - iterate with get(index)
feature = experimental_features.get(0)

# Enable a feature on Settings instance
settings.set_feature_enabled(feature, true)
```

**Debugging Missing APIs:**

If a web app fails with "undefined is not a function" errors in the console:

1. **Check console errors (F12)** - Look for specific API names
2. **Search for related features:**
   ```ruby
   ruby -e "require 'webkit2-gtk'; features = WebKit2Gtk::Settings.experimental_features;
            (0...features.length).each { |i| f = features.get(i);
            puts f.identifier if f.identifier =~ /SearchTerm/i }"
   ```
3. **Get feature details:**
   ```ruby
   ruby -e "require 'webkit2-gtk'; features = WebKit2Gtk::Settings.experimental_features;
            f = features.get(0); puts 'ID: ' + f.identifier;
            puts 'Name: ' + f.name; puts 'Details: ' + f.details"
   ```
4. **Add to enabled features list** in Tab initialization

**Important Notes:**
- Features are **class methods** on `WebKit2Gtk::Settings`, not instance methods
- `experimental_features` returns a `FeatureList`, not an Array
- Use `get(index)` to access features, not array indexing
- Feature identifiers are case-sensitive (e.g., "FileSystemAccess" not "FileSystemAccessAPI")

### Markdown Rendering

The browser renders `.md` and `.markdown` files with GitHub-flavored styling instead of showing raw text.

**Features:**
- **Automatic detection**: Any URL ending in `.md` or `.markdown` is rendered
- **Local and remote**: Works with both `file://` and `http(s)://` URLs
- **GitHub styling**: Clean typography with dark mode support
- **View toggle**: Press `Ctrl+U` to switch between rendered and raw source view
- **GFM support**: Tables, fenced code blocks, strikethrough, footnotes, autolinks
- **Mermaid diagrams**: Automatic rendering of mermaid code blocks (flowcharts, sequence diagrams, etc.)

**Mermaid Support:**
- Diagrams in \`\`\`mermaid code blocks are automatically rendered
- Uses Mermaid.js from CDN (loaded only when mermaid blocks are detected)
- Supports dark mode (theme switches automatically with system preference)
- All Mermaid diagram types supported: flowchart, sequence, class, state, ER, Gantt, etc.

**PDF Export with Bookmarks:**
- Print markdown to PDF via `Ctrl+P` → "Print to File"
- Dark theme styling preserved in PDF (deep dark background, syntax highlighting)
- **Automatic bookmark generation**: When printing markdown to PDF, bookmarks are automatically added from heading hierarchy
- Bookmarks create a navigable table of contents in PDF viewers (e.g., sidebar in Evince)
- Manual bookmark addition: Use `Ctrl+Shift+B` to add bookmarks to existing PDFs (for PDFs created before this feature or from external sources)
- Post-processing via HexaPDF: Extracts headings from markdown, finds them in the PDF, builds hierarchical outline structure

**Page Breaks in PDF:**
You can control page breaks when printing to PDF using HTML comments in your markdown:
```markdown
# Section One
Content for the first page

<!-- pagebreak -->

# Section Two
This starts on a new page
```
- Supported formats: `<!-- pagebreak -->`, `<!-- page-break -->`, `<!-- PAGEBREAK -->` (case-insensitive)
- Page breaks are invisible in browser view, only active when printing
- Alternative: Use `<div class="page-break"></div>` for explicit HTML control

**Implementation:**
- Uses `redcarpet` gem for markdown-to-HTML conversion
- Intercepts navigation via `decide-policy` signal before WebKit loads content
- Renders styled HTML and loads via `webview.load_html()`
- State stored per-webview for toggle functionality
- Mermaid.js injected from CDN when mermaid blocks are detected

**Handler Location:** `lib/handlers/markdown_handler.rb`

### Read/Watch/Do Queue

The queue is a FIFO (first-in-first-out) list for managing URLs you want to read, watch, or process later.

**Features:**
- **Add to queue**: Current tab (`Ctrl+Shift+Q`) or right-click any link
- **View queue**: Sidebar view (`Ctrl+Q`) shows all queued URLs with position indicators
- **Remove and navigate**: `Ctrl+Alt+Q` removes current URL from queue and loads the next one
- **Reorder**: Select an entry in the queue sidebar and use `Ctrl+Shift+M/N` to move it up/down
- **Duplicate prevention**: Adding a URL already in the queue shows a message instead
- **Persistence**: Queue stored in SQLite, survives browser restarts

**Queue Sidebar:**
- Shows position (#1, #2, etc.), title, URL, and favicon for each entry
- Click any entry to navigate to it
- **Active entry highlighting**: Current page highlighted in queue (if present)
- Remove button (×) on each entry
- Automatically refreshes when queue is modified or navigation occurs

**Background Metadata Fetching:**
- Queue entries added via right-click (link context menu) initially lack title/favicon
- Background worker thread fetches metadata asynchronously
  - Uses Ruby Thread + Thread::Queue (stdlib)
  - Fetches page HTML, extracts title and favicon
  - All UI updates via `GLib::Idle.add` for thread safety
  - Graceful shutdown with poison pill pattern

**URL Matching for Highlighting:**
- Uses bidirectional subset matching to handle tracking parameters
- Compares base URL (scheme, host, path) exactly
- Query parameters: either URL's params can be subset of the other
- Handles cases where:
  - Queue URL has extra params (YouTube adds `&pp=xyz`, then strips them)
  - Current URL has extra params (timestamp `&t=10s` added during playback)
- Fragments (#...) and trailing slashes ignored

**Implementation Notes:**
- Queue entries have integer positions that are renumbered when items are removed or reordered
- `Repositories::QueueRepository` owns positions and renumbering; `Repositories::TagRepository` owns tags and assignments; both share one connection so the two tables stay in one transaction scope
- Queue entries and tags cross bucket boundaries as `Domain::QueueEntry` / `Domain::Tag`, never as row hashes
- Maximum capacity: thousands of entries (SQLite-backed)
- UTF-8 encoding enforced via SQLite `PRAGMA encoding = 'UTF-8'`

### Keyboard Shortcuts

**Navigation:**
- `Ctrl+L`: Focus URL bar
- `Ctrl+[` / `Ctrl+]`: Back/forward navigation
- Mouse buttons 8/9: Back/forward navigation

**Tabs:**
- `Ctrl+N`: New window
- `Ctrl+T`: New tab
- `Ctrl+W`: Close tab
- `Ctrl+Tab`: Next tab (or next queue item when queue sidebar is open)
- `Ctrl+Shift+Tab`: Previous tab (or previous queue item when queue sidebar is open)
- `Ctrl+Shift+PageUp`: Move tab up in list (or move current page up in queue when queue sidebar is open)
- `Ctrl+Shift+PageDown`: Move tab down in list (or move current page down in queue when queue sidebar is open)

**Sidebar:**
- `Ctrl+B`: Toggle sidebar
- `Ctrl+H`: Show history in sidebar
- `Ctrl+E`: Show tabs in sidebar
- `Ctrl+Q`: Show queue in sidebar

**Queue Management:**
- `Ctrl+Shift+Q`: Add current tab to queue
- `Ctrl+Alt+Q`: Remove current URL from queue and navigate to next
- Right-click link → "Add to Queue": Add link to queue
- **Context-dependent shortcuts (when queue sidebar is open):**
  - `Ctrl+Tab` / `Ctrl+Shift+Tab`: Navigate to next/previous queue item
  - `Ctrl+Shift+PageUp/PageDown`: Move current page up/down in queue
- **Drag-and-drop:** Reorder queue entries by dragging them in the queue sidebar

**Other:**
- `Ctrl+R`: Refresh page
- `Ctrl+P`: Print page (markdown to PDF automatically includes bookmarks)
- `Ctrl++` / `Ctrl+=`: Zoom in
- `Ctrl+-`: Zoom out
- `Ctrl+0`: Reset zoom to 100%
- `Ctrl+U`: Toggle markdown source (when viewing `.md` files)
- `Ctrl+Shift+B`: Add PDF bookmarks to existing PDF (for external PDFs or old PDFs without bookmarks)
- `Ctrl+O`: Open file (supports HTML, Markdown, PDF, images)
- `Ctrl+Shift+P`: Video popout (YouTube only)
- `Ctrl+Shift+R`: Reload browser with latest code
- `F11`: Toggle zen mode
- `F12`: Toggle Web Inspector (dev tools)

## Known Limitations

### Picture-in-Picture

- **Native PiP API**: Not available in WebKitGTK (`document.pictureInPictureEnabled` is undefined)
- **Current implementation**: Only works with direct video URLs (not YouTube/streaming services)
- **Blob URLs**: Cannot extract from YouTube/Twitch due to blob:// protocol
- **Future approach**: Page-cloning method (load same URL in floating window, hide non-video elements with CSS injection)

### WebKitGTK-Specific Issues

- GStreamer plugins required for video playback (see user's system for GStreamer setup)
- JavaScript injection via UserScript may fail; use `run_javascript()` in load-changed signal instead
- Cookie manager must be configured on default web context (WebsiteDataManager constructor doesn't accept parameters in Ruby bindings)

## Development Notes

- This is a Gentoo system using emerge for package management
- Ruby managed via asdf (version 3.3.0)
- WebKitGTK version: 2.48.5
- Follows user's global CLAUDE.md principles (avoid system changes without permission, prefer clarity and single-responsibility)

### GTK Event Handling Gotchas

**Keyboard Shortcut Precedence:**
- GTK checks event handlers in order of registration
- Modifier combinations must exclude other modifiers explicitly
- Example: `Ctrl+Q` handler must check `!event.state.mod1_mask?` to avoid intercepting `Ctrl+Alt+Q`
- Without exclusion, broader conditions (e.g., `control_mask?`) match before specific ones

**Correct Pattern:**
```ruby
if event.state.control_mask? && !event.state.mod1_mask?  # Ctrl only, not Ctrl+Alt
  # Handle Ctrl+Q
elsif event.state.control_mask? && event.state.mod1_mask?  # Ctrl+Alt
  # Handle Ctrl+Alt+Q
end
```
