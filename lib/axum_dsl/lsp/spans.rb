# frozen_string_literal: true

module AxumDsl
  module Lsp
    # Spans the compiler reports, asked the questions an editor asks: which one covers this position, which is
    # the smallest, where is it in LSP's terms. An entry is a Hash with :line, :col, :end_line and :end_col
    # (1-based lines, 1-based BYTE columns, the end column exclusive), whatever else it carries. Nothing here
    # knows what the entries mean.
    module Spans
      module_function

      def covers?(entry, line, col)
        return false if line < entry[:line] || line > entry[:end_line]
        return false if line == entry[:line] && col < entry[:col]
        return false if line == entry[:end_line] && col >= entry[:end_col]

        true
      end

      # The smallest entry covering (line, col). On equal size the block ranks the entries (lower wins), so a
      # caller can prefer one kind of entry over another covering exactly the same text.
      def smallest(entries, line, col)
        entries.select { |e| covers?(e, line, col) }.min_by do |e|
          [e[:end_line] - e[:line], e[:end_line] == e[:line] ? e[:end_col] - e[:col] : e[:end_col], block_given? ? yield(e) : 0]
        end
      end

      # A LSP range for a span, from the lines of the file the span is in (columns are UTF-16 there).
      def range(lines, entry)
        { start: { line: entry[:line] - 1, character: Position.to_lsp(lines[entry[:line] - 1], entry[:col]) },
          end: { line: entry[:end_line] - 1, character: Position.to_lsp(lines[entry[:end_line] - 1], entry[:end_col]) } }
      end
    end
  end
end
