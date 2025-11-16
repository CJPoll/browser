# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A toy web browser built with Ruby, GTK3, and WebKitGTK. Features include browsing history, persistent cookies, Picture-in-Picture (in development), zen mode, and keyboard shortcuts.

## Running the Browser

```bash
bundle exec ruby simple_browser.rb
```

The browser will start with a 1200x768 window loading example.com.

## Architecture

### Core Components

- **`simple_browser.rb`**: Main browser window (BrowserWindow class)
  - GTK application with WebKit2GTK WebView
  - Manages toolbar, sidebar, and WebView container
  - Handles keyboard shortcuts and mouse navigation
  - Injects JavaScript for features like Picture-in-Picture

- **`history_manager.rb`**: SQLite-based browsing history
  - Normalized schema: sites → pages → visits
  - Stores data in `~/.local/share/toy-browser/history.db`
  - Tracks visit timestamps, titles, and visit counts

- **`pip_window.rb`**: Picture-in-Picture floating window (WIP)
  - Creates always-on-top window for video playback
  - Currently supports direct video URLs only
  - Native WebKit PiP API not available in WebKitGTK

### Data Storage

- **History DB**: `~/.local/share/toy-browser/history.db`
- **Cookies**: `~/.local/share/toy-browser/cookies.sqlite`
- **Cache**: `~/.cache/toy-browser/`

All directories are created automatically on first run.

### WebKit Integration

The browser uses WebKit2GTK's web context and user content manager:

- **Web Context**: Manages persistent storage (cookies, cache)
- **User Content Manager**: Handles JavaScript injection for custom features
- **JavaScript Injection**: Scripts injected on page load via `run_javascript()` since UserScript injection doesn't work reliably

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

### Keyboard Shortcuts

- `Ctrl+L`: Focus URL bar
- `Ctrl+B`: Toggle sidebar
- `Ctrl+R`: Refresh page
- `Ctrl+Shift+P`: Video popout (YouTube only)
- `Ctrl+Shift+R`: Reload browser with latest code
- `Ctrl+N`: New window
- `Ctrl+T`: New tab
- `Ctrl+W`: Close tab
- `Ctrl+Tab` / `Ctrl+Shift+Tab`: Next/previous tab
- `Ctrl+[` / `Ctrl+]`: Back/forward navigation
- `Ctrl+H` / `Ctrl+E`: Show history/tabs in sidebar
- `Ctrl+Shift+PageUp/PageDown`: Reorder current tab
- `F11`: Toggle zen mode
- `F12`: Toggle Web Inspector (dev tools)
- Mouse buttons 4/5: Back/forward navigation

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
