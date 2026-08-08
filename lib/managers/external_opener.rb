# frozen_string_literal: true

require_relative '../adapters/uri_opener'

module Managers
  # Hands things the browser does not display to whatever else on the desktop
  # does display them: a `spotify://` link, a finished download, the folder a
  # download landed in.
  #
  # Each method is named after what its caller is holding, so no caller has to
  # work out whether it should be passing a URI or a path.
  class ExternalOpener
    # @param uri_opener [Adapters::UriOpener] Desktop URI handler
    def initialize(uri_opener: Adapters::UriOpener.new)
      @uri_opener = uri_opener
    end

    # Opens a URI that belongs to another application
    #
    # Whether a URI belongs elsewhere is `Domain::ExternalSchemes`' decision,
    # made by the caller that also has to stop the navigation.
    #
    # @param uri [String, nil] The URI to hand over
    # @return [Boolean] True if a handler was launched
    def open_uri(uri)
      return false if blank?(uri)

      @uri_opener.open(uri)
    end

    # Opens a file with whatever application handles its type
    #
    # @param path [String, nil] Path to the file
    # @return [Boolean] True if a handler was launched
    def open_path(path)
      return false if blank?(path)

      @uri_opener.open(path)
    end

    # Opens the folder a file lives in, in the file manager
    #
    # @param path [String, nil] Path to the file
    # @return [Boolean] True if a handler was launched
    def open_containing_directory(path)
      return false if blank?(path)

      @uri_opener.open(File.dirname(path))
    end

    private

    # Nothing worth handing to the desktop
    #
    # @param target [String, nil] URI or path
    # @return [Boolean]
    def blank?(target)
      target.nil? || target.to_s.strip.empty?
    end
  end
end
