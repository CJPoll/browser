# frozen_string_literal: true

require 'uri'

module Domain
  # What a finished print job left behind.
  #
  # GTK reports the destination of a "print to file" job as a `file://` URI in
  # the print settings. Only a PDF is worth following up on -- that is the one
  # output the browser can add bookmarks to.
  module PrintOutput
    FILE_SCHEME_PREFIX = 'file://'
    PDF_EXTENSION = '.pdf'

    # The local path a print job wrote a PDF to
    #
    # @param output_uri [String, nil] The job's `output-uri` print setting
    # @return [String, nil] Local path, or nil if the job did not produce a PDF
    def self.pdf_path(output_uri)
      return nil unless output_uri&.end_with?(PDF_EXTENSION)

      # Decoding as a form component (rather than as a path) is a preserved
      # wart: a literal '+' in the filename comes back as a space.
      URI.decode_www_form_component(output_uri.sub(FILE_SCHEME_PREFIX, ''))
    end
  end
end
