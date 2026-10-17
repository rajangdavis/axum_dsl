# frozen_string_literal: true

module AxumDsl
  # Types made of other types: typed maps (a Ruby Hash with String keys and one value type, T::Hash[String, V]), a
  # list of another params struct, and the nil-able form of any type that has no fixed symbol of its own. Internally
  # a map is the symbol :"map<V>" and a nil-able map :"opt<map<V>>", where V is the internal symbol of one of VALUES,
  # of a nested object (:"struct:Name") or of a scalar map (:"map<scalar>", a map of maps). A field declares a map as
  # `map(:i64)`, `map(list(:string))`, `map(:Address)` or `map(map(:i64))`; its canonical text in the IR is
  # "map(i64)", "map(string_list)", "map(Address)" or "map(map(i64))".
  #
  # A map is a Rust BTreeMap, as serde_json's own objects are: keys come back sorted, not in insertion order.
  module CompositeTypes
    # canonical value name => [internal symbol, Rust type, display name]
    VALUES = {
      "string" => [:string, "String", "String"],
      "i64" => [:i64, "i64", "Integer (i64)"],
      "f64" => [:f64, "f64", "Float"],
      "bool" => [:bool, "bool", "T::Boolean"],
      "string_list" => [:strs, "Vec<String>", "T::Array[String]"],
      "i64_list" => [:i64s, "Vec<i64>", "T::Array[Integer (i64)]"],
      "f64_list" => [:f64s, "Vec<f64>", "T::Array[Float]"]
    }.freeze
    BY_SYMBOL = VALUES.to_h { |name, (sym, rust, shown)| [sym, [name, rust, shown]] }.freeze
    MAP_FIELD = /\Amap\((\w+)\)\z/
    MAP_OF_MAP_FIELD = /\Amap\(map\((\w+)\)\)\z/ # a map of maps: "map(map(i64))"
    OBJECT_MAP_FIELD = /\Amap\(([A-Z]\w*)\)\z/ # a map of another params struct: "map(Address)"
    OBJECT_LIST_FIELD = /\Alist\(([A-Z]\w*)\)\z/ # a list of another params struct: "list(Address)"
    OPAQUE_FIELD = /\A[A-Z]\w*::[A-Z]\w*\z/ # a field typed with a type a binding owns: "Json::Value"
    OPAQUE_LIST_FIELD = /\Alist\(([A-Z]\w*::[A-Z]\w*)\)\z/ # a list of one: "list(Html::Row)"

    # :"map<V>" -> the value symbol V. V is one of VALUES, a nested object (:"struct:Name"), or a scalar map
    # (:"map<scalar>"), which is how a map of maps is written. nil for anything else, so a map of maps of maps
    # (:"map<map<map<i64>>>") is not a map.
    def self.map_value(sym)
      s = sym.to_s
      return nil unless s.start_with?("map<") && s.end_with?(">")
      inner = s[4..-2].to_sym
      return inner if BY_SYMBOL.key?(inner) || inner.to_s.start_with?("struct:") || scalar_map?(inner)
      nil
    end

    def self.map_sym?(sym) = !map_value(sym).nil?

    # :"map<scalar>": the value is one of VALUES (not an object and not another map).
    def self.scalar_map?(sym)
      s = sym.to_s
      s.start_with?("map<") && s.end_with?(">") && BY_SYMBOL.key?(s[4..-2].to_sym)
    end

    # :"map<struct:Name>": the values are another params struct.
    def self.object_map_sym?(sym) = sym.to_s.match?(/\Amap<struct:[A-Z]\w*>\z/)

    def self.object_map_element(sym) = sym.to_s.match(/\Amap<struct:([A-Z]\w*)>\z/)&.[](1)

    # :"map<map<scalar>>": a map of maps, one level of nesting.
    def self.map_of_map_sym?(sym) = (v = map_value(sym)) ? scalar_map?(v) : false

    def self.map_symbol(value_sym) = :"map<#{value_sym}>"

    # The Rust type of a map with that value symbol.
    def self.map_rust(value_sym) = "std::collections::BTreeMap<String, #{map_value_rust(value_sym)}>"

    # The Rust type behind a map value: a scalar, the name of a nested struct, or a nested map.
    def self.map_value_rust(value_sym)
      return BY_SYMBOL.fetch(value_sym)[1] if BY_SYMBOL.key?(value_sym)
      return value_sym.to_s.delete_prefix("struct:") if value_sym.to_s.start_with?("struct:")
      return map_rust(map_value(value_sym)) if scalar_map?(value_sym)

      raise KeyError, "no Rust type for map value #{value_sym.inspect}"
    end

    # :"list<map<scalar>>": the list `values` gives on a map of maps. It is not a field type (a list cannot
    # hold a map); it exists only as the result of a body call.
    def self.map_list_symbol(map_sym) = :"list<#{map_sym}>"

    def self.map_list_value(sym)
      s = sym.to_s
      return nil unless s.start_with?("list<map<") && s.end_with?(">")
      inner = s[5..-2].to_sym
      scalar_map?(inner) ? inner : nil
    end

    def self.map_list_sym?(sym) = !map_list_value(sym).nil?

    # A list of another params struct: the field text is "list(Address)", the internal symbol is
    # :"list<struct:Address>" and a nil-able one :"opt<list<struct:Address>>". The element is an
    # ordinary nested object (:struct:Address), read like any other.
    def self.object_list_name(type) = type.to_s.match(OBJECT_LIST_FIELD)&.[](1)

    def self.object_list?(type) = !object_list_name(type).nil?

    def self.object_list_symbol(name) = :"list<struct:#{name}>"

    def self.object_list_element(sym) = sym.to_s.match(/\Alist<struct:([A-Z]\w*)>\z/)&.[](1)

    def self.object_list_sym?(sym) = !object_list_element(sym).nil?

    # A map of another params struct: the field text is "map(Address)", the internal symbol is
    # :"map<struct:Address>" (nil-able :"opt<map<struct:Address>>"). The value is an ordinary nested object.
    def self.object_map_name(type) = type.to_s.match(OBJECT_MAP_FIELD)&.[](1)

    def self.object_map?(type) = !object_map_name(type).nil?

    # The inner type a field's type text wraps: "map(map(i64))" -> "i64".
    def self.map_of_map_name(type) = type.to_s.match(MAP_OF_MAP_FIELD)&.[](1)

    # "map(...)" / "map(map(...))" as written on a field.
    def self.map_field_text?(type) = type.to_s.start_with?("map(")

    # The one struct name a field's type refers to: a nested object, a list of objects or a map of objects.
    def self.nested_struct_name(type)
      s = type.to_s
      return s if s.match?(/\A[A-Z]\w*\z/)

      object_list_name(s) || object_map_name(s)
    end

    # "map(i64)", "map(Address)" or "map(map(i64))" -> the map's internal symbol; nil when the text is not a map field type
    def self.field_symbol(type)
      s = type.to_s
      if (m = s.match(MAP_OF_MAP_FIELD))
        entry = VALUES[m[1]] or return nil
        return map_symbol(map_symbol(entry[0]))
      end
      m = s.match(MAP_FIELD) or return nil
      name = m[1]
      return map_symbol(VALUES[name][0]) if VALUES.key?(name)
      return map_symbol(:"struct:#{name}") if name.match?(/\A[A-Z]\w*\z/)

      nil
    end

    # The types a binding owns (`class Value < AxumDsl::Opaque` in a bindings/*.rb file). Internally a value of one is
    # the symbol :"ext<Json::Value>" and a nil-able one :"opt<ext<Json::Value>>"; the compiler knows only the name, the
    # Rust type behind it and whether it may cross the wire (be a tool field or part of a result). The registry is
    # filled when a file is read (Reader) and when the IR is turned into Rust (Emit), because Emit holds no state.
    #
    # A record is an opaque type that also lists its fields ([name, type symbol text, line], and the binding file
    # they are declared in): the DSL may read them. A list of an opaque type is :"list<ext<Html::Row>>".
    module Opaque
      Entry = Struct.new(:name, :rust, :wire, :fields, :path, :line, keyword_init: true)
      EXT = /\Aext<([A-Z]\w*::[A-Z]\w*)>\z/
      EXT_LIST = /\Alist<ext<([A-Z]\w*::[A-Z]\w*)>>\z/

      @types = {}

      class << self
        def reset(entries = [])
          @types = entries.to_h do |e|
            [e["name"], Entry.new(name: e["name"], rust: e["rust"], wire: e["wire"], fields: e["fields"].to_a, path: e["path"], line: e["line"])]
          end
        end

        def register(name, rust, wire, fields = [], path = nil, line = nil)
          @types[name] = Entry.new(name: name, rust: rust, wire: wire, fields: fields, path: path, line: line)
        end

        # The fields of a record ([name, type symbol, line]); nil for a plain opaque type or an unknown name.
        def fields(name)
          f = @types[name]&.fields
          f.nil? || f.empty? ? nil : f
        end

        def list_symbol(name) = :"list<ext<#{name}>>"

        # :"list<ext<Html::Row>>" -> "Html::Row"; nil for any other symbol
        def list_element(sym) = sym.to_s.match(EXT_LIST)&.[](1)

        def symbol(name) = :"ext<#{name}>"

        # :"ext<Json::Value>" -> "Json::Value"; nil for any other symbol
        def name_of(sym) = sym.to_s.match(EXT)&.[](1)

        def symbol?(sym) = !name_of(sym).nil?

        def entry(name) = @types[name]

        # "Json::Value" -> the Rust type, or raises when nothing declared that name
        def rust(name) = (@types[name] or raise(KeyError, "no opaque type #{name}")).rust

        # A field type's text ("Json::Value") -> its symbol; nil when the text is not shaped like a qualified name.
        def field_symbol(text) = text.to_s.match?(/\A[A-Z]\w*::[A-Z]\w*\z/) ? symbol(text) : nil

        def types = @types.values
      end
    end

    # Looks like the Hash it replaces (key?, [], fetch) for the nil-able types: fixed symbols for the old ones
    # (:ostr ...), :"opt<map<V>>" for a nil-able map and :"opt<ext<Name>>" for a nil-able opaque type.
    class OptTable
      def initialize(fixed) = @fixed = fixed

      def key?(sym) = @fixed.key?(sym) || !inside(sym).nil?

      def [](sym) = @fixed[sym] || inside(sym)

      def fetch(sym) = self[sym] || raise(KeyError, "key not found: #{sym.inspect}")

      private

      def inside(sym)
        s = sym.to_s
        return nil unless s.start_with?("opt<") && s.end_with?(">")

        inner = s[4..-2].to_sym
        return nil unless CompositeTypes.map_sym?(inner) || CompositeTypes.object_list_sym?(inner) || Opaque.symbol?(inner) ||
                          Opaque.list_element(inner) || inner.to_s.start_with?("struct:")

        inner
      end
    end

    # The way back: the nil-able type of a type, for an optional field.
    class OptOfTable
      def initialize(fixed) = @fixed = fixed

      def key?(sym) = @fixed.key?(sym) || nested?(sym)

      def [](sym) = @fixed[sym] || (nested?(sym) ? :"opt<#{sym}>" : nil)

      def fetch(sym) = self[sym] || raise(KeyError, "key not found: #{sym.inspect}")

      private

      def nested?(sym)
        CompositeTypes.map_sym?(sym) || CompositeTypes.object_list_sym?(sym) || Opaque.symbol?(sym) || !Opaque.list_element(sym).nil? ||
          sym.to_s.start_with?("struct:")
      end
    end

    # The map types: key?(sym) says whether a symbol is a map, fetch(sym) gives the value symbol.
    class MapTable
      def key?(sym) = !CompositeTypes.map_value(sym).nil?

      def [](sym) = CompositeTypes.map_value(sym)

      def fetch(sym) = self[sym] || raise(KeyError, "key not found: #{sym.inspect}")
    end
  end
end
