# Simple Ruby Browser

A minimal web browser built with Ruby, GTK3, and WebKitGTK.

## Features

- URL bar with automatic HTTPS prepending
- Back and forward navigation buttons
- WebKit rendering engine
- Clean GTK-based UI

## Prerequisites

- Ruby 3.3.0 (managed via asdf)
- WebKitGTK installed via emerge (Gentoo)
- GTK3

## Installation

```bash
# Install Ruby version specified in .tool-versions
asdf install

# Install dependencies
bundle install
```

## Running

```bash
# Make executable
chmod +x simple_browser.rb

# Run the browser
./simple_browser.rb

# Or run via bundle
bundle exec ruby simple_browser.rb
```

## Usage

1. Type a URL in the text field and press Enter or click "Go"
2. Use ← and → buttons to navigate back and forward
3. URLs without `http://` or `https://` will automatically get `https://` prepended

## Next Steps

See `../ai-artifacts/plan.md` for the complete tutorial on building a browser with HTML+CSS+JS-based UI controls.
