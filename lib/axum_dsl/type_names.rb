# frozen_string_literal: true

module AxumDsl
  # How the compiler's internal types read to a person: Sorbet-style names, for `check --types`.
  module TypeNames
    SCALARS = { string: "String", str: "String", i32: "Integer (i32)", i64: "Integer (i64)", f64: "Float",
                bool: "T::Boolean", strs: "T::Array[String]", i64s: "T::Array[Integer (i64)]", f64s: "T::Array[Float]",
                regex: "Regexp", never: "T.noreturn", int: "Integer", block: "ContentBlock",
                blocks: "T::Array[ContentBlock]", rcontent: "ResourceContents", rcontents: "T::Array[ResourceContents]",
                elicit_result: "Elicitation result", roots_result: "T::Array[Root]", ojson: "T.nilable(JSON value)", secret: "Secret", r_str: "Rust::Str" }.freeze

    # An internal type symbol ("struct:Name" for an object, :ostr ... for a nil-able) -> its display string.
    def self.display(sym)
      sym = sym.to_sym
      return SCALARS.fetch(sym) if SCALARS.key?(sym)
      return "T.nilable(#{display(Body::OPT.fetch(sym))})" if Body::OPT.key?(sym)
      return "T::Hash[String, #{display(CompositeTypes.map_value(sym))}]" if CompositeTypes.map_value(sym)
      return "T::Array[#{CompositeTypes.object_list_element(sym)}]" if CompositeTypes.object_list_sym?(sym)
      return "T::Array[#{CompositeTypes::Opaque.list_element(sym)}]" if CompositeTypes::Opaque.list_element(sym)
      return "T::Array[#{display(CompositeTypes.map_list_value(sym))}]" if CompositeTypes.map_list_sym?(sym)
      return "T::Hash[String, T.untyped]" if sym == :empty_map
      return CompositeTypes::Opaque.name_of(sym) if CompositeTypes::Opaque.symbol?(sym)

      sym.to_s.delete_prefix("struct:")
    end

    # The type a params/output field has inside a body (an optional field is nil-able).
    def self.field_symbol(field)
      base =
        case field["type"]
        when "string_list" then :strs
        when "i64_list" then :i64s
        when "f64_list" then :f64s
        when CompositeTypes::MAP_FIELD, CompositeTypes::MAP_OF_MAP_FIELD then CompositeTypes.field_symbol(field["type"])
        when CompositeTypes::OBJECT_LIST_FIELD then CompositeTypes.object_list_symbol(field["type"][CompositeTypes::OBJECT_LIST_FIELD, 1])
        when CompositeTypes::OPAQUE_FIELD then CompositeTypes::Opaque.symbol(field["type"])
        when CompositeTypes::OPAQUE_LIST_FIELD then CompositeTypes::Opaque.list_symbol(field["type"][CompositeTypes::OPAQUE_LIST_FIELD, 1])
        when CAMEL then :"struct:#{field['type']}"
        else field["type"].to_sym
        end
      field["optional"] ? Body::OPT_OF.fetch(base) : base
    end

    # Gathers one entry per typed position while the compiler reads a file; nothing is collected unless
    # a collector is passed to AxumDsl.read. Positions in the DSL files of the compile are kept, each with its
    # :file (absolute): `entries` are the file at `path`, `all_entries` every file, so a declaration in a
    # use_dsl fragment can be found from the root. A binding file's positions are not kept.
    class Collector
      attr_reader :path

      def initialize(path)
        @path = path
        @real = AxumDsl.canon(path)
        @entries = []
      end

      # loc is a Prism::Location; type is already a display string.
      def add(loc, kind, type, name: nil, detail: nil, extra: nil)
        file = AxumDsl::SOURCE_FILES[loc.send(:source)]&.last or return
        entry = { line: loc.start_line, col: loc.start_column + 1, end_line: loc.end_line, end_col: loc.end_column + 1,
                  kind: kind, type: type, file: file }
        entry[:name] = name.to_s if name
        entry[:detail] = detail if detail
        entry.merge!(extra) if extra # declarations also carry the call, its keywords and where the name token is
        @entries << entry
      end

      # Sorted by (line, col, end_line descending), without repeats: the compiler may type a node twice.
      def entries = all_entries.filter_map { |e| e.except(:file) if e[:file] == @real }

      def all_entries
        @entries.uniq.sort_by { |e| [e[:file], e[:line], e[:col], -e[:end_line], -e[:end_col], e[:kind], e[:name].to_s] }
      end
    end
  end
end
