# frozen_string_literal: true

module AxumDsl
  module Lsp
    # Hover over a declaration: the call's own name, one of its positional arguments, a keyword, or a keyword's
    # value, described from SIG. Pure: the analysis holds the text and Position converts the columns.
    #
    # The document is parsed per hover (milliseconds), and Prism's parse is error-tolerant, so a hover still
    # works on a file with a mistake above it.
    module Hover
      module_function

      # line0 and utf16_col are LSP's (0-based, UTF-16). Returns {"contents" => ..., "range" => ...}, or nil.
      def at(analysis, line0, utf16_col)
        lines = analysis.lines
        return nil if line0.negative? || line0 >= lines.size

        byte_col = Position.from_lsp(lines[line0], utf16_col)
        offset = offset_at(lines, line0, byte_col)
        program = parse(analysis.text)
        return nil if program.nil?

        calls = []
        each_node(program) { |node| calls << node if node.is_a?(Prism::CallNode) && contains?(node.location, offset) }
        named = calls.select { |call| contains?(call.message_loc, offset) }
        # A statement call and a typed position in a body come first: inside a body `params` is a read of the
        # route's params, not the `params` declaration.
        found = statement(analysis, lines, named.last) || typed(analysis, line0 + 1, byte_col) ||
                (calls.empty? ? nil : declaration(lines, named.last) || argument(analysis, lines, program, calls.last, offset))
        with_derivation(analysis, found, line0 + 1, byte_col)
      end

      # How the types derive (TypeGraph), appended to whatever the position already says: for a derived node there, what it takes
      # its type from, e.g. a record field from the column a relation selects.
      def with_derivation(analysis, found, line, byte_col)
        text = analysis.graph&.hover_markdown(analysis.real, line, byte_col)
        return found if text.nil?
        return { contents: { kind: "markdown", value: text } } if found.nil?

        found.merge(contents: found[:contents].merge(value: "#{found[:contents][:value]}\n\n#{text}"))
      end

      # The cursor is on the name of a call to a declared `query` or `execute`: its signature and its SQL.
      def statement(analysis, lines, call)
        return nil if call.nil? || call.receiver

        query = AxumSource.statements(analysis.ir)[call.name.to_s]
        query && item(lines, call.message_loc, AxumSource.statement_markdown(query))
      end

      # What the compiler typed that is not a declaration (those are described from SIG): a parameter, a local
      # or an expression of a body. The entries of the compile are the ones `check --types` prints.
      DECLARATION_KINDS = %w[declaration field helper].freeze

      def typed(analysis, line, byte_col)
        entries = analysis.entries.reject { |e| DECLARATION_KINDS.include?(e[:kind]) }
        entry = Spans.smallest(entries, line, byte_col) { |e| e[:kind] == "expression" ? 1 : 0 } # a named kind over a bare expression
        return nil if entry.nil?

        head = entry[:name] ? "**`#{entry[:name]}`** - #{entry[:kind]}" : "**#{entry[:kind]}**"
        { contents: { kind: "markdown", value: "#{head}\n\n`#{entry[:type]}`" }, range: Spans.range(analysis.lines, entry) }
      end

      # The cursor is on the call's own name: describe the declaration.
      def declaration(lines, call)
        return nil if call.nil?

        doc = SigDoc.hover(call.name)
        return nil if doc.nil?

        loc = call.message_loc
        return nil if loc.nil?

        item(lines, loc, doc)
      end

      # The cursor is on an argument or a keyword of `call`: describe what SIG accepts there.
      def argument(analysis, lines, program, call, offset)
        sig = AxumDsl.sig_variants(call.name).first # the cursor knows no context: the first signature describes the arguments
        return nil if sig.nil?

        args = call.arguments&.arguments || []
        args.each_with_index do |arg, i|
          next unless contains?(arg.location, offset)
          next if sig[:pos][i].nil?

          return item(lines, arg.location, value_text(analysis, program, arg, sig[:pos][i]))
        end
        args.each do |arg|
          next unless arg.is_a?(Prism::KeywordHashNode)

          arg.elements.each do |el|
            next unless el.is_a?(Prism::AssocNode)

            key = el.key.is_a?(Prism::SymbolNode) ? el.key.unescaped.to_sym : nil
            spec = key ? sig[:kw][key] : nil
            next if spec.nil?

            if contains?(el.key.location, offset)
              return item(lines, el.key.location,
                          "**`#{key}:`** - #{SigDoc.kind_doc(spec[0])}#{spec[1] ? ' (required)' : ' (optional)'}")
            end
            next unless contains?(el.value.location, offset)

            return item(lines, el.value.location, value_text(analysis, program, el.value, spec[0]))
          end
        end
        nil
      end

      # What a value there is, plus the declaration a name points at.
      def value_text(analysis, program, node, kind)
        parts = []
        literal = literal_of(node)
        parts << "**`#{literal}`**" unless literal.nil?
        parts << SigDoc.kind_doc(kind)
        declared = declared_at(program, node) if %i[camel fieldtype].include?(kind)
        parts << declared unless declared.nil?
        parts.join("\n\n")
      end

      def item(lines, loc, markdown)
        { contents: { kind: "markdown", value: markdown },
          range: range_for(lines, loc.start_line, loc.start_column + 1, loc.end_column + 1) }
      end

      def literal_of(node)
        case node
        when Prism::SymbolNode then ":#{node.unescaped}"
        when Prism::StringNode then node.unescaped.inspect
        when Prism::IntegerNode, Prism::FloatNode then node.value.inspect
        end
      end

      # "declared at line N" for a symbol naming a `params` group above: the question an editor asks next.
      def declared_at(program, node)
        name = node.is_a?(Prism::SymbolNode) ? node.unescaped : nil
        return nil if name.nil?

        declared = (program.statements.body || []).find do |n|
          n.is_a?(Prism::CallNode) && n.name == :params &&
            (first = n.arguments&.arguments&.first).is_a?(Prism::SymbolNode) && first.unescaped == name
        end
        declared && "declared at line #{declared.location.start_line}"
      end

      # A range from the compiler's 1-based byte columns, converted to LSP's UTF-16 columns at the edge.
      def range_for(lines, line1, byte_col, end_byte_col)
        text = lines[line1 - 1].to_s
        { start: { line: line1 - 1, character: Position.to_lsp(text, byte_col) },
          end: { line: line1 - 1, character: Position.to_lsp(text, end_byte_col) } }
      end

      def offset_at(lines, line0, byte_col)
        lines[0...line0].sum { |l| l.bytesize + 1 } + byte_col - 1
      end

      def contains?(loc, offset)
        !loc.nil? && offset >= loc.start_offset && offset < loc.end_offset
      end

      def parse(text)
        Prism.parse(text).value
      rescue StandardError
        nil
      end

      def each_node(node, &blk)
        return unless node.is_a?(Prism::Node)

        yield node
        children(node).each { |child| each_node(child, &blk) }
      end

      def children(node)
        node.respond_to?(:compact_child_nodes) ? node.compact_child_nodes : node.child_nodes.compact
      end
    end
  end
end
