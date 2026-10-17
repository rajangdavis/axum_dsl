# frozen_string_literal: true

module AxumDsl
  module Lsp
    # Completion of the DSL's declaration names, by context. `Completion.at(analysis, line0, utf16_col)` returns
    # LSP CompletionItems.
    #
    # The context is a line scan, not an AST walk: completion runs while a line is half-typed, when the file may
    # not parse at all. Only a `params` block and a `fragment` block hold declarations, so the scan keeps a
    # stack of the `do ... end` blocks above the cursor and reads the innermost: inside `params` the only
    # declaration is `field`; at the top level (and inside `fragment`) they are the SIG calls with `in: :top`.
    # Inside a route, a helper or a filter block the body language is Ruby, not SIG names, and nothing is
    # offered.
    module Completion
      DECL = 14 # CompletionItemKind.Keyword: a declaration name
      VALUE = 12 # CompletionItemKind.Value: a symbol a declaration accepts

      OPENER = /\b([A-Za-z_][A-Za-z0-9_]*)[^\n]*\bdo\s*(?:\|[^|]*\|)?\s*\z/
      CLOSER = /\A\s*end\s*(?:#.*)?\z/

      module_function

      def at(analysis, line0, utf16_col)
        lines = analysis.lines
        return [] if line0.negative? || line0 > lines.size

        head = head_before(lines[line0].to_s, utf16_col)
        prefix = tail_word(head)
        case context_at(lines, line0)
        when :top then declarations(:top, prefix)
        when :params then field_items(head, prefix)
        else []
        end
      end

      # The declaration names of a context, each carrying the documentation SIG gives it.
      def declarations(context, prefix)
        SigDoc.declarations_for(context).map do |name|
          { label: name, kind: DECL, detail: SigDoc.detail(name),
            documentation: { kind: "markdown", value: SigDoc.hover(name) } }
        end.select { |item| matches?(item[:label], prefix) }
      end

      # Inside a params block: the field's type once its name and comma are there, its keywords once the type
      # is, and otherwise the block's declarations.
      def field_items(head, prefix)
        before = before_word(head, prefix)
        if before.match?(/\bfield\s+:[A-Za-z0-9_]+\s*,\s*\z/)
          field_types(prefix)
        elsif before.match?(/\bfield\b.*,\s*\z/)
          keyword_items(:field, prefix)
        else
          declarations(:params, prefix)
        end
      end

      def field_types(prefix)
        SigDoc::FIELD_TYPE_NAMES.map do |name|
          { label: ":#{name}", kind: VALUE, detail: SigDoc.kind_doc(:fieldtype) }
        end.select { |item| matches?(item[:label], prefix) }
      end

      def keyword_items(name, prefix)
        SigDoc.keywords(name).map do |key|
          { label: "#{key}:", kind: DECL, detail: SigDoc.keyword_detail(name, key) }
        end.select { |item| matches?(item[:label], prefix) }
      end

      # The `do ... end` block the cursor sits in, by a line scan: the innermost block is `params` (fields),
      # `fragment` (declarations at the top level), or a declaration block whose body is Ruby.
      def context_at(lines, line0)
        stack = []
        lines[0...line0].each do |line|
          code = line.to_s.sub(/\s*#.*\z/, "")
          if (m = OPENER.match(code))
            stack << m[1]
          elsif CLOSER.match?(code)
            stack.pop
          end
        end
        case stack.last
        when nil, "fragment" then :top
        when "params", "record" then :params
        else :body
        end
      end

      # The bytes of the line before the cursor.
      def head_before(line, utf16_col)
        line.to_s.byteslice(0, Position.from_lsp(line, utf16_col) - 1).to_s
      end

      # The word being typed at the end of `head`: an identifier, with the `:` of a symbol.
      def tail_word(head) = head[/(:?[A-Za-z_][A-Za-z0-9_]*)\z/, 1].to_s

      def before_word(head, prefix)
        prefix.empty? ? head : head.byteslice(0, head.bytesize - prefix.bytesize).to_s
      end

      def matches?(label, prefix) = prefix.empty? || label.start_with?(prefix)
    end
  end
end
