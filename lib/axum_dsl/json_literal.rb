# frozen_string_literal: true

module AxumDsl
  # JSON written out in a DSL file: strings, numbers, true, false, nil, arrays, and hashes with
  # string keys. The reader parses the `meta:` and `input_schema:` literals with it, a tool body
  # parses the `schema:` of an `elicit` call, and the emitter renders such a value as the Rust
  # text inside `serde_json::json!(...)`. `what:` names the construct in an error, such as
  # "`meta:`" or "the elicitation `schema:`", and `diag` is the Reader or Body answering `bad`.
  module JsonLiteral
    module_function

    def value(node, diag, what:)
      case node
      when Prism::StringNode then node.unescaped
      when Prism::IntegerNode
        diag.bad(node, "this integer does not fit JSON number range (-2^63 to 2^64-1)") unless (-2**63..2**64 - 1).cover?(node.value)
        node.value
      when Prism::FloatNode then node.value
      when Prism::TrueNode then true
      when Prism::FalseNode then false
      when Prism::NilNode then nil
      when Prism::ArrayNode then node.elements.map { |el| value(el, diag, what: what) }
      when Prism::HashNode then object(node, diag, what: what)
      else
        diag.bad(node, "#{what} holds JSON data written out: strings, numbers, true, false, nil, arrays and hashes with string keys (got #{diag.nodename(node)})")
      end
    end

    def object(node, diag, what:)
      seen = {}
      node.elements.each_with_object({}) do |el, out|
        diag.bad(el, "a JSON object is `\"key\" => value` pairs; `**` is not supported") unless el.is_a?(Prism::AssocNode)
        if el.key.is_a?(Prism::SymbolNode)
          diag.bad(el.key, "JSON object keys are strings: write \"#{el.key.unescaped}\" => value")
        end
        diag.bad(el.key, "a JSON object key must be a string literal such as \"name\"") unless el.key.is_a?(Prism::StringNode)
        key = el.key.unescaped
        diag.bad(el.key, "duplicate key \"#{key}\"") if seen[key]
        seen[key] = true
        out[key] = value(el.value, diag, what: what)
      end
    end

    # A parsed literal as the Rust text inside `serde_json::json!(...)`.
    def rust(value)
      case value
      when Hash then "{#{value.map { |k, v| "#{AxumDsl.rstr(k)}: #{rust(v)}" }.join(', ')}}"
      when Array then "[#{value.map { |v| rust(v) }.join(', ')}]"
      when String then AxumDsl.rstr(value)
      when nil then "null"
      else value.to_s # true, false, integers and floats read the same in Rust
      end
    end
  end
end
