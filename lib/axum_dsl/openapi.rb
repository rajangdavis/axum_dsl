# frozen_string_literal: true

module AxumDsl
  # The `openapi "/openapi.json"` declaration: the compiler writes an OpenAPI 3.1 document from the IR and the
  # generated service serves it as one static string. Nothing is generated at run time, so there is no runtime
  # crate; the compiler already knows every route, every field's type and every constraint.
  #
  # Each route is one operation. A field `in: :path` or `in: :query` is a parameter, the fields `in: :body` or
  # `in: :form` are the request body, a field's `description:` and constraints become JSON Schema keywords, and
  # a params group another field nests becomes a component schema. Responses are minimal on purpose: the DSL
  # does not declare what a body answers, so only 200 (without a schema) and the rejections the generated
  # extractors and check() produce are listed.
  #
  # The document is a plain Hash whose keys are inserted in a fixed order, so the JSON is the same on every
  # compile.
  module OpenApi
    SPEC_VERSION = "3.1.0"
    INTEGER_FORMAT = { "i32" => "int32", "i64" => "int64" }.freeze
    LIST_ITEMS = { "string_list" => "string", "i64_list" => "i64", "f64_list" => "f64" }.freeze
    # field option => JSON Schema keyword, in the order the keywords are written
    KEYWORDS = { "min" => "minimum", "max" => "maximum", "exclusive_min" => "exclusiveMinimum",
                 "exclusive_max" => "exclusiveMaximum", "multiple_of" => "multipleOf",
                 "min_length" => "minLength", "max_length" => "maxLength", "pattern" => "pattern",
                 "format" => "format", "enum" => "enum" }.freeze

    module_function

    # The document as compact JSON, the text the emitted crate embeds.
    def json(ir) = JSON.generate(document(ir))

    def document(ir)
      decl = ir.fetch("openapi")
      groups = ir["params"].to_a.to_h { |p| [p["name"], p] }
      used = {}
      ids = {}
      paths = {}
      ir["routes"].to_a.each do |route|
        op = operation(route, groups[route["params"]], ir, groups, used, operation_id(route, ids))
        (paths[doc_path(route["path"])] ||= {})[route["method"]] = op
      end
      doc = { "openapi" => SPEC_VERSION,
              "info" => { "title" => decl["title"] || ir["name"], "version" => decl["version"] || ir["version"] },
              "paths" => paths }
      schemas = component_schemas(used, groups)
      doc["components"] = { "schemas" => schemas } unless schemas.empty?
      doc
    end

    # axum's `{name}` and `{*rest}` captures are OpenAPI's `{name}` and `{rest}`.
    def doc_path(path) = path.gsub(/\{\*(\w+)\}/, '{\1}')

    # get_users_id for GET /users/{id}; a clash gets a numeric suffix.
    def operation_id(route, ids)
      words = route["path"].scan(/[A-Za-z0-9]+/)
      base = "#{route['method']}_#{words.empty? ? 'root' : words.join('_')}"
      ids[base] = ids.fetch(base, 0) + 1
      ids[base] == 1 ? base : "#{base}_#{ids[base]}"
    end

    def operation(route, prm, ir, groups, used, id)
      op = { "operationId" => id }
      if (text = route["description"])
        op["summary"] = text.lines.first.to_s.strip
        op["description"] = text
      end
      by_source = (prm ? prm["fields"] : []).group_by { |f| Emit.field_source(route, f) }
      parameters = %w[path query].flat_map { |loc| by_source.fetch(loc, []).map { |f| parameter(f, loc, groups, used) } }
      op["parameters"] = parameters unless parameters.empty?
      media, fields = if by_source.key?("body") then ["application/json", by_source["body"]]
                      elsif by_source.key?("form") then ["application/x-www-form-urlencoded", by_source["form"]]
                      end
      if fields
        body = { "content" => { media => { "schema" => object_schema(fields, groups, used) } } }
        body["required"] = true if fields.any? { |f| required?(f) }
        op["requestBody"] = body
      end
      op["responses"] = responses(by_source, prm, ir)
      op
    end

    # 200 has no schema because the DSL does not declare one. 400 is axum's Query, Path and Json-syntax
    # rejections and the generated check(); 422 is the Json and Form extractors rejecting a body whose shape
    # does not match the fields.
    def responses(by_source, prm, ir)
      out = { "200" => { "description" => "Success" } }
      if %w[path query body].any? { |loc| by_source.key?(loc) } || (prm && Emit.checked?(prm, ir))
        out["400"] = { "description" => "The request could not be read, or a field broke a constraint; the body says which" }
      end
      out["422"] = { "description" => "The body does not have the declared fields" } if by_source.key?("body") || by_source.key?("form")
      out
    end

    def parameter(field, loc, groups, used)
      out = { "name" => field["name"], "in" => loc }
      out["description"] = field["description"] if field["description"]
      out["required"] = loc == "path" || required?(field)
      out["schema"] = field_schema(field, groups, used, describe: false)
      out
    end

    # A caller may leave out an optional field and one that has a default.
    def required?(field) = !field["optional"] && !field.key?("default")

    def object_schema(fields, groups, used)
      schema = { "type" => "object", "properties" => fields.to_h { |f| [f["name"], field_schema(f, groups, used)] } }
      required = fields.select { |f| required?(f) }.map { |f| f["name"] }
      schema["required"] = required unless required.empty?
      schema
    end

    # Every params group a field nested, by name, each with its own nested groups, sorted so the order does not
    # depend on which route came first.
    def component_schemas(used, groups)
      done = {}
      until (pending = used.keys - done.keys).empty?
        name = pending.first
        done[name] = object_schema(groups.fetch(name)["fields"], groups, used)
      end
      done.sort.to_h
    end

    def field_schema(field, groups, used, describe: true)
      out = {}
      out["description"] = field["description"] if describe && field["description"]
      out.merge!(type_schema(field["type"], groups, used))
      KEYWORDS.each { |option, keyword| out[keyword] = field[option] if field.key?(option) }
      size = field["type"].start_with?("map(") ? "Properties" : "Items"
      out["min#{size}"] = field["min_items"] if field.key?("min_items")
      out["max#{size}"] = field["max_items"] if field.key?("max_items")
      out["default"] = field["default"] if field.key?("default")
      out
    end

    def type_schema(type, groups, used)
      case type
      when "string" then { "type" => "string" }
      when "i32", "i64" then { "type" => "integer", "format" => INTEGER_FORMAT.fetch(type) }
      when "f64" then { "type" => "number", "format" => "double" }
      when "bool" then { "type" => "boolean" }
      when *LIST_ITEMS.keys then { "type" => "array", "items" => type_schema(LIST_ITEMS.fetch(type), groups, used) }
      when CompositeTypes::OBJECT_LIST_FIELD then { "type" => "array", "items" => ref(Regexp.last_match(1), used) }
      when CompositeTypes::OPAQUE_LIST_FIELD then { "type" => "array", "items" => {} }
      when CompositeTypes::MAP_OF_MAP_FIELD
        { "type" => "object", "additionalProperties" => { "type" => "object", "additionalProperties" => type_schema(Regexp.last_match(1), groups, used) } }
      when CompositeTypes::MAP_FIELD then { "type" => "object", "additionalProperties" => type_schema(Regexp.last_match(1), groups, used) }
      when CAMEL then ref(type, used)
      else {} # a type a binding owns: any JSON value
      end
    end

    def ref(name, used)
      used[name] = true
      { "$ref" => "#/components/schemas/#{name}" }
    end
  end
end
