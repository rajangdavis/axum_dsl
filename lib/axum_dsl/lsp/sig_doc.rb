# frozen_string_literal: true

module AxumDsl
  module Lsp
    # The DSL surface as text, for a hover or a completion item: every word of it is rendered from SIG and the
    # schema constants, so what an editor shows is derived from the same table the reader validates against and
    # cannot drift from the compiler. No keyword list is restated here by hand.
    module SigDoc
      # What each SIG kind accepts, in the words schema.rb documents it in.
      KIND_DOC = {
        lit: "a string, number or true/false literal",
        default: "a literal, or a flat array of literals",
        bool: "true or false",
        num: "an integer or float literal",
        uint: "a non-negative integer",
        str: "a string literal",
        snake: "a snake_case symbol",
        camel: "a CamelCase symbol (the name of something the file declares)",
        fieldtype: "a field type",
        htypes: "a list of helper argument types",
        helper_kw: "a keyword parameter table such as `{ limit: [:i32, false] }`",
        types: "a list of Rust argument types",
        strs: "a list of string literals",
        snakes: "a list of snake_case symbols",
        file_checks: "a list of file checks",
        sqlargs: "a hash of the query's arguments, such as `{ limit: :i64 }`, each a scalar type (:string, :i64, :f64, :bool)",
        qreturns: "what a query returns: `list(:Record)`, `:Record?` (the first row or nil) or a scalar type, with ? for nil-able"
      }.freeze

      # A field's scalar and list types; a field may also name a CamelCase params group.
      FIELD_TYPE_NAMES = (TYPES.keys + FIELD_LISTS).freeze

      EXTRA = { fieldtype: ", or a CamelCase `params` group the file declares" }.freeze

      module_function

      # The symbols a fixed-list kind accepts, or nil when the kind is open.
      def value_names(kind)
        case kind
        when :fieldtype then FIELD_TYPE_NAMES.map { |k| ":#{k}" }
        when :htypes, :types then HELPER_TYPES.keys.map { |k| ":#{k}" }
        when :file_checks then FILE_CHECKS.map { |k| ":#{k}" }
        when Array then kind.map { |k| ":#{k}" }
        end
      end

      # A value of this kind in words, with the accepted names when the compiler fixes the list.
      def kind_doc(kind)
        names = value_names(kind)
        base = KIND_DOC[kind]
        return names ? "one of #{names.join(', ')}" : kind.inspect if base.nil?

        text = "#{base}#{EXTRA[kind]}"
        names ? "#{text}: #{names.join(', ')}" : text
      end

      # The declaration's call shape, spelled the way the reader spells it (reader.rb#shape): an optional
      # keyword is bracketed.
      def shape(name, sig)
        kws = sig[:kw].map { |k, (_, req)| req ? "#{k}:" : "[#{k}:]" }
        "#{name}(#{(sig[:names] + kws).join(', ')})"
      end

      # The calls the reader allows directly inside `ctx`.
      def declarations_for(ctx)
        SIG.select { |_, s| Array(s[:in]).include?(ctx) }.keys.map(&:to_s)
      end

      # The declarations allowed inside the block of `name`. There are three :decls blocks: `params` and
      # `record`, whose blocks hold fields, and `fragment`, whose block holds the top-level declarations.
      def block_calls(name) = declarations_for(%i[params record].include?(name) ? name : :top)

      def context_doc(where)
        Array(where).map { |c| c == :top ? "the top level" : "`#{c}`" }.join(" or ")
      end

      def block_doc(name, block)
        case block
        when :body then "the body language (a Ruby subset), `do ... end`"
        when :decls then "declarations only: #{block_calls(name).join(', ')} - `do ... end`"
        else "none"
        end
      end

      # The markdown a hover shows for a declaration, or nil when the name is not one.
      def hover(name)
        key = name.to_sym # a caller may hold the name as the string a completion label carries
        sig = SIG[key]
        return nil if sig.nil?

        lines = ["**`#{key}`** - an axum_dsl declaration: `#{shape(key, sig)}`", ""]
        sig[:pos].each_with_index do |kind, i|
          lines << "- `#{sig[:names][i]}` - #{kind_doc(kind)}"
        end
        sig[:kw].each do |kw, (kind, required)|
          lines << "- `#{kw}:` - #{kind_doc(kind)}#{required ? ' (required)' : ' (optional)'}"
        end
        lines << "- block: #{block_doc(key, sig[:block])}" unless sig[:block].nil?
        lines << "- may appear: #{context_doc(sig[:in])}"
        lines.join("\n")
      end

      # One line for a completion item.
      def detail(name)
        key = name.to_sym
        sig = SIG[key]
        sig ? "#{key} - may appear in #{context_doc(sig[:in])}" : name.to_s
      end

      # The keywords a declaration accepts, for completion.
      def keywords(name) = SIG[name][:kw].keys

      def keyword_detail(name, key)
        kind, required = SIG[name][:kw][key]
        "#{key}: - #{kind_doc(kind)}#{required ? ' (required)' : ' (optional)'}"
      end
    end
  end
end
