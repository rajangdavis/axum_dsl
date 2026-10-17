# frozen_string_literal: true

module AxumDsl
  module Lsp
    # Converts between the compiler's columns (1-based, bytes into the line) and LSP's (0-based, UTF-16 code
    # units into the line). They only differ on a line with non-ASCII text, but then they differ a lot.
    # Ported from rmcp_dsl's Lsp::Position, which is the same conversion over the same compiler positions.
    module Position
      module_function

      # byte_col is 1-based, as in the compiler's errors and entries.
      def to_lsp(line_text, byte_col)
        before = line_text.to_s.byteslice(0, [byte_col - 1, 0].max).to_s.dup.force_encoding(Encoding::UTF_8).scrub
        before.each_char.sum { |ch| ch.ord > 0xFFFF ? 2 : 1 }
      end

      # utf16_col is 0-based; the result is a 1-based byte column. A column past the end of the line (or
      # inside a surrogate pair) lands on the nearest character boundary.
      def from_lsp(line_text, utf16_col)
        bytes = 0
        units = 0
        line_text.to_s.dup.force_encoding(Encoding::UTF_8).scrub.each_char do |ch|
          break if units >= utf16_col

          units += ch.ord > 0xFFFF ? 2 : 1
          bytes += ch.bytesize
        end
        bytes + 1
      end
    end
  end
end
