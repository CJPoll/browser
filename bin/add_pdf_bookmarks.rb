#!/usr/bin/env ruby
# frozen_string_literal: true

# Adds bookmarks to a PDF that was just printed, in a process of its own.
#
# Run by Adapters::PdfBookmarkWriter#add_bookmarks_later. Both paths arrive as
# arguments rather than interpolated into source, so a filename containing
# quotes, backslashes or shell syntax is only ever data.
#
#   bin/add_pdf_bookmarks.rb <pdf-path> <markdown-path>
#
# The markdown file is this process's to delete once it has been read.

require_relative '../lib/adapters/pdf_bookmark_writer'

# The print job may still be flushing the PDF when the 'finished' signal
# arrives, so give it a moment before opening the file.
PRINT_FLUSH_DELAY_SECONDS = 0.5

pdf_path, markdown_path = ARGV

abort "usage: #{$PROGRAM_NAME} <pdf-path> <markdown-path>" unless pdf_path && markdown_path

sleep PRINT_FLUSH_DELAY_SECONDS

markdown = File.read(markdown_path)
success = Adapters::PdfBookmarkWriter.new.add_bookmarks(pdf_path, markdown)

puts success ? '[AutoBookmark] ✓ Bookmarks added automatically' : '[AutoBookmark] ✗ Bookmark addition failed'

begin
  File.delete(markdown_path)
rescue StandardError => e
  warn "[AutoBookmark] Could not remove #{markdown_path}: #{e.message}"
end
