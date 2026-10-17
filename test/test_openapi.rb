# frozen_string_literal: true

# The `openapi` declaration: the compiler writes an OpenAPI 3.1 document from the IR, and the emitted service
# serves it as a static string. These tests read a small DSL source and assert the document's structure; they
# need no cargo and no network.
#
#   ruby -Ilib test/test_openapi.rb
require "minitest/autorun"
require "json"
require "tmpdir"
require "axum_dsl"

class TestOpenApi < Minitest::Test
  SOURCE = <<~RB
    server "notes", version: "1.2.3"
    openapi "/openapi.json"

    params :Address do
      field :city, :string, description: "Where it is", min_length: 2
      field :zip, :string, optional: true
    end

    params :NoteId do
      field :id, :i64, in: :path, description: "The note", min: 1
    end

    params :NewNote do
      field :title, :string, description: "A short title", min_length: 1, max_length: 40, pattern: "^[A-Za-z ]+$"
      field :rank, :f64, exclusive_min: 0, max: 10.5, default: 1.5
      field :tags, :string_list, optional: true, max_items: 5
      field :kind, :string, enum: ["a", "b"], format: :email
      field :home, :Address
      field :stops, list(:Address), optional: true
      field :scores, map(:i64), optional: true
    end

    params :Search do
      field :q, :string, in: :query, description: "Words to look for"
      field :limit, :i32, in: :query, optional: true, min: 1, max: 50
    end

    params :Contact do
      field :name, :string, in: :form
    end

    get "/notes/:id", params: :NoteId, description: "One note\\nWith a second line" do
      text("note")
    end

    post "/notes", params: :NewNote, description: "Create a note" do
      text("created")
    end

    get "/search", params: :Search do
      text("found")
    end

    post "/contact", params: :Contact do
      text("thanks")
    end

    get "/health" do
      text("ok")
    end
  RB

  def read(src)
    Dir.mktmpdir("openapi") do |dir|
      file = File.join(dir, "notes.axum.rb")
      File.write(file, src)
      ir = AxumDsl.read(file)
      yield ir, file
    end
  end

  def document(src = SOURCE)
    read(src) { |ir, _| return AxumDsl::OpenApi.document(ir) }
  end

  def test_the_envelope_names_the_server
    doc = document
    assert_equal "3.1.0", doc["openapi"]
    assert_equal({ "title" => "notes", "version" => "1.2.3" }, doc["info"])
    assert_equal %w[/health /notes /notes/{id} /search /contact].sort, doc["paths"].keys.sort
  end

  def test_title_and_version_can_be_given
    doc = document(SOURCE.sub('openapi "/openapi.json"', 'openapi "/api.json", title: "Notes API", version: "9"'))
    assert_equal({ "title" => "Notes API", "version" => "9" }, doc["info"])
  end

  def test_a_route_description_is_the_summary_and_description
    op = document.dig("paths", "/notes/{id}", "get")
    assert_equal "One note", op["summary"]
    assert_equal "One note\nWith a second line", op["description"]
    assert_equal "get_notes_id", op["operationId"]
    assert_nil document.dig("paths", "/health", "get", "summary")
    assert_equal "get_health", document.dig("paths", "/health", "get", "operationId")
  end

  def test_a_path_field_is_a_required_parameter_with_its_constraint
    param = document.dig("paths", "/notes/{id}", "get", "parameters").fetch(0)
    assert_equal({ "name" => "id", "in" => "path", "description" => "The note", "required" => true,
                   "schema" => { "type" => "integer", "format" => "int64", "minimum" => 1 } }, param)
  end

  def test_query_fields_are_parameters_and_optional_ones_are_not_required
    params = document.dig("paths", "/search", "get", "parameters")
    assert_equal %w[q limit], params.map { |p| p["name"] }
    assert_equal [true, false], params.map { |p| p["required"] }
    assert_equal({ "type" => "integer", "format" => "int32", "minimum" => 1, "maximum" => 50 }, params[1]["schema"])
    assert_equal "Words to look for", params[0]["description"]
    refute params[0]["schema"].key?("description"), "the description sits on the parameter, not on its schema"
  end

  def test_a_body_group_is_a_json_request_body_with_json_schema_constraints
    op = document.dig("paths", "/notes", "post")
    body = op["requestBody"]
    assert_equal true, body["required"]
    schema = body.dig("content", "application/json", "schema")
    assert_equal "object", schema["type"]
    assert_equal %w[title kind home], schema["required"], "optional fields and fields with a default are not required"
    props = schema["properties"]
    assert_equal({ "description" => "A short title", "type" => "string", "pattern" => "^[A-Za-z ]+$",
                   "minLength" => 1, "maxLength" => 40 }, props["title"])
    assert_equal({ "type" => "number", "format" => "double", "exclusiveMinimum" => 0, "maximum" => 10.5, "default" => 1.5 }, props["rank"])
    assert_equal({ "type" => "array", "items" => { "type" => "string" }, "maxItems" => 5 }, props["tags"])
    assert_equal({ "type" => "string", "format" => "email", "enum" => %w[a b] }, props["kind"])
    assert_equal({ "type" => "object", "additionalProperties" => { "type" => "integer", "format" => "int64" } }, props["scores"])
  end

  def test_a_nested_group_is_a_component_schema
    doc = document
    schema = doc.dig("paths", "/notes", "post", "requestBody", "content", "application/json", "schema")
    assert_equal({ "$ref" => "#/components/schemas/Address" }, schema.dig("properties", "home"))
    assert_equal({ "type" => "array", "items" => { "$ref" => "#/components/schemas/Address" } }, schema.dig("properties", "stops"))
    address = doc.dig("components", "schemas", "Address")
    assert_equal %w[city], address["required"]
    assert_equal({ "description" => "Where it is", "type" => "string", "minLength" => 2 }, address.dig("properties", "city"))
    assert_equal %w[Address], doc["components"]["schemas"].keys
  end

  def test_a_form_group_is_a_urlencoded_request_body
    content = document.dig("paths", "/contact", "post", "requestBody", "content")
    assert_equal ["application/x-www-form-urlencoded"], content.keys
    assert_equal %w[name], content.dig("application/x-www-form-urlencoded", "schema", "required")
  end

  def test_responses_are_minimal
    paths = document["paths"]
    assert_equal %w[200], paths.dig("/health", "get", "responses").keys
    assert_equal %w[200 400], paths.dig("/search", "get", "responses").keys
    assert_equal %w[200 400 422], paths.dig("/notes", "post", "responses").keys
    assert_equal %w[200 422], paths.dig("/contact", "post", "responses").keys
    refute paths.dig("/health", "get").key?("parameters")
    refute paths.dig("/health", "get").key?("requestBody")
  end

  def test_the_json_is_the_same_on_every_compile
    first = read(SOURCE) { |ir, _| AxumDsl::OpenApi.json(ir) }
    assert_equal first, read(SOURCE) { |ir, _| AxumDsl::OpenApi.json(ir) }
    assert_equal first, JSON.generate(JSON.parse(first)), "the text is compact JSON whose key order is the document's"
  end

  def test_the_emitted_service_embeds_the_document_and_routes_the_path
    read(SOURCE) do |ir, file|
      main = AxumDsl::Emit.files(ir, file).fetch("src/main.rs")
      assert_includes main, "const OPENAPI_JSON: &str = "
      assert_includes main, '.route("/openapi.json", axum::routing::get(openapi_json))'
      embedded = main[/const OPENAPI_JSON: &str = "(.*)";$/, 1]
      assert embedded, "the const holds a one-line string literal"
      # a Rust string literal with these escapes (\" \\ \n) reads as a JSON string, so it decodes the same way
      assert_equal AxumDsl::OpenApi.json(ir), JSON.parse(%("#{embedded}"))
    end
  end

  def test_nothing_changes_without_the_declaration
    read(SOURCE.sub(%(openapi "/openapi.json"\n), "")) do |ir, file|
      assert_nil ir["openapi"]
      main = AxumDsl::Emit.files(ir, file).fetch("src/main.rs")
      refute_includes main, "OPENAPI_JSON"
      refute_includes main, "openapi_json"
    end
  end

  def test_the_compile_names_the_document_in_a_notice
    read(SOURCE) do |_ir, _file|
      note = AxumDsl::Notify.notes.find { |n| n.code == "N-OPENAPI" }
      assert note, "N-OPENAPI is emitted"
      assert_includes note.message, "/openapi.json"
      assert_includes note.message, "5 operation(s)"
    end
  end

  def test_a_route_on_the_documents_path_is_refused
    err = assert_raises(AxumDsl::CompileError) do
      read(%(server "x", version: "0.1.0"\nopenapi "/docs"\nget "/docs" do\n  text("x")\nend\n)) { |_, _| nil }
    end
    assert_match(/already answers/, err.message)
  end

  def test_a_second_openapi_is_refused
    err = assert_raises(AxumDsl::CompileError) do
      read(%(server "x", version: "0.1.0"\nopenapi "/a.json"\nopenapi "/b.json"\n)) { |_, _| nil }
    end
    assert_match(/duplicate `openapi`/, err.message)
  end

  def test_the_path_must_be_written_out
    err = assert_raises(AxumDsl::CompileError) do
      read(%(server "x", version: "0.1.0"\nopenapi "/docs/:name"\n)) { |_, _| nil }
    end
    assert_match(/openapi path/, err.message)
  end
end
