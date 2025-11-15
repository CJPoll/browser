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

### Keyboard Shortcuts

- `Ctrl+L`: Focus URL bar
- `Ctrl+B`: Toggle sidebar
- `Ctrl+R`: Refresh page
- `Ctrl+Shift+P`: Picture-in-Picture (experimental)
- `F11`: Toggle zen mode
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
