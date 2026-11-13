# frozen_string_literal: true

module AxumDsl
  module Lsp
    # Go to definition: what the name under the cursor refers to, as an LSP Location in the file that holds it
    # (a root's fragments are other files). Answers nil for anything it does not know. The declarations are the
    # compiler's own (the `declaration` entries of a compile, kept by Analysis), so a definition is where the
    # compiler read the name from; a `def` is found by parsing the files the compile read.
    module Definition
      module_function

      # line0 and utf16_col are LSP's (0-based, UTF-16).
      def at(analysis, line0, utf16_col)
        lines = analysis.lines
        return nil if line0.negative? || line0 >= lines.size

        offset = Hover.offset_at(lines, line0, Position.from_lsp(lines[line0], utf16_col))
        program = Hover.parse(analysis.text)
        return nil if program.nil?

        chain = [] # the nodes covering the cursor, outermost first
        Hover.each_node(program) { |node| chain << node if Hover.contains?(node.location, offset) }
        target = symbol_target(analysis, chain) || call_target(analysis, chain, offset) ||
                 graph_target(analysis, line0 + 1, Position.from_lsp(lines[line0], utf16_col))
        target && location(analysis, target)
      end

      # The cursor is on a symbol: `params: :Group`, `skip: [:filter]`, `render :view`, `before :filter`.
      def symbol_target(analysis, chain)
        sym = chain.last
        return nil unless sym.is_a?(Prism::SymbolNode)

        name = sym.unescaped
        parent = chain[-2]
        grand = chain[-3]
        entries = analysis.all_entries
        if keyword_value?(parent, "params", sym)
          AxumSource.declaration(entries, %w[params], name)
        elsif keyword_value?(parent, "skip", sym) || (parent.is_a?(Prism::ArrayNode) && keyword_value?(grand, "skip", parent))
          AxumSource.declaration(entries, %w[before], name)
        elsif parent.is_a?(Prism::ArgumentsNode) && grand.is_a?(Prism::CallNode) && grand.receiver.nil? && parent.arguments.first.equal?(sym)
          case grand.name
          when :render then view_target(analysis, name)
          when :before then def_target(analysis, name) # the filter is the def of that name
          end
        end
      end

      # The cursor is on the name of a call without a receiver: a statement, a `current` reader, a `def`.
      def call_target(analysis, chain, offset)
        call = chain.reverse.find { |n| n.is_a?(Prism::CallNode) && Hover.contains?(n.message_loc, offset) }
        return nil if call.nil? || call.receiver

        name = call.name.to_s
        AxumSource.declaration(analysis.all_entries, %w[query execute], name) ||
          AxumSource.reader_declaration(analysis.all_entries, name) ||
          def_target(analysis, name)
      end

      # The cursor is on something the compiler derived (a record field, an association, a statement): where the thing it takes
      # its type from is written, e.g. the column a relation selects.
      def graph_target(analysis, line, col)
        graph = analysis.graph or return nil
        node = graph.nodes_at(analysis.real, line, col).find { |n| graph.sources(n.id).any? } or return nil
        graph.sources(node.id).filter_map { |e| graph.location_of(e.from) }.first
      end

      # `references` on a column or an expr: where each node that takes its type from it is (the reverse edges), as Locations.
      def references(analysis, line0, utf16_col)
        graph = analysis.graph or return []
        lines = analysis.lines
        return [] if line0.negative? || line0 >= lines.size

        col = Position.from_lsp(lines[line0], utf16_col)
        graph.nodes_at(analysis.real, line0 + 1, col).flat_map { |n| graph.dependents(n.id).map(&:to) }.uniq.filter_map { |id| graph.location_of(id) }
             .map { |target| location(analysis, target) }
      end      # Is `node` an `key: value` pair whose key is the symbol `key` and whose value is `value`?
      def keyword_value?(node, key, value)
        node.is_a?(Prism::AssocNode) && node.key.is_a?(Prism::SymbolNode) && node.key.unescaped == key && node.value.equal?(value)
      end

      def view_target(analysis, name)
        file = AxumSource.view_file(analysis.ir, analysis.compile_path, name)
        file && { file: AxumDsl.canon(file) }
      end

      # The `def name` in the files the compile read: the open file's own first, else the first elsewhere.
      def def_target(analysis, name)
        found = analysis.dsl_files.flat_map { |file| defs_in(file, text_of(analysis, file), name) }
        found.find { |t| t[:file] == analysis.real } || found.first
      end

      def defs_in(file, text, name)
        program = text && Hover.parse(text)
        return [] if program.nil?

        found = []
        Hover.each_node(program) do |node|
          next unless node.is_a?(Prism::DefNode) && node.name.to_s == name

          loc = node.name_loc
          found << { file: file, line: loc.start_line, col: loc.start_column + 1, end_line: loc.end_line, end_col: loc.end_column + 1 }
        end
        found
      end

      def text_of(analysis, file)
        return analysis.text if file == analysis.real

        Sources[file] || File.read(file, encoding: "UTF-8")
      rescue SystemCallError
        nil
      end

      # A span (or just a file: a view) as an LSP Location.
      def location(analysis, target)
        range =
          if target[:line]
            Spans.range((text_of(analysis, target[:file]) || "").split("\n", -1), target)
          else
            { start: { line: 0, character: 0 }, end: { line: 0, character: 0 } }
          end
        { uri: uri_for(target[:file]), range: range }
      end

      def uri_for(path)
        "file://#{path.gsub(%r{[^A-Za-z0-9_\-.~/]}) { |ch| ch.bytes.map { |b| format('%%%02X', b) }.join }}"
      end
    end
  end
end
