# frozen_string_literal: true

# The result record of a relation query can be DERIVED (docs/database.md, "Queries as relations"): `returns:` names a
# record no `record` declares, and the compiler declares it from the fields the relation selects, in selection order,
# as if the `record` block were written there. Each case compiles a small DSL string; the refusals are also pinned by
# test/refusals/derive_*.rb. No cargo and no HTTP.
#
#   ruby -Ilib test/test_db_derive.rb
require "minitest/autorun"
require "tmpdir"
require "axum_dsl"

class TestDbDerive < Minitest::Test
  HEAD = <<~RB
    server "derive", version: "0.1.0"
    set :port, 8080
    database :sqlite, path: "x.db"

    table :rooms do
      field :id, :i64
      field :name, :string, optional: true
      field :kind, :string
    end
  RB

  A_ROOM = %(query :a_room, args: { id: :i64 }, returns: :RoomName? do where(id: arg(:id)).select(:id, name: coalesce(:name, "")) end\n)
  A_LIST = %(query :a_list, args: {}, returns: list(:RoomName) do select(:id, name: coalesce(:name, "")) end\n)

  # The declared spelling of RoomName, four lines; the derived spelling puts four comment lines there instead, so
  # every `at` line number in the Rust is the same and the two compiles can be compared byte for byte.
  DECLARED = "record :RoomName do\n  field :id, :i64\n  field :name, :string\nend\n"
  PADDING = "# derived\n" * 4

  def source(statements, records: "", routes: "")
    "#{HEAD}#{records}model :Room, table: :rooms do\n#{statements}end\n#{routes}"
  end

  def read(src)
    Dir.mktmpdir("derive") do |dir|
      file = File.join(dir, "derive.axum.rb")
      File.write(file, src)
      yield AxumDsl.read(file), file
    end
  end

  def rust(src)
    read(src) { |ir, file| AxumDsl::Emit.files(ir, file)["src/main.rs"] }
  end

  def refused(src, text)
    Dir.mktmpdir("derive") do |dir|
      file = File.join(dir, "derive.axum.rb")
      File.write(file, src)
      error = assert_raises(AxumDsl::CompileError) { AxumDsl.read(file) }
      assert_includes error.message, text
      error
    end
  end

  # Each compile runs in its own temporary directory, and the generated Rust names the source file, so that
  # directory is taken out before comparing.
  def assert_same_rust(with, without)
    a = with.gsub(%r{/[^"\s]*/derive\.axum\.rb}, "derive.axum.rb").lines
    b = without.gsub(%r{/[^"\s]*/derive\.axum\.rb}, "derive.axum.rb").lines
    clip = ->(lines) { lines.first(8).map { |l| l.strip[0, 300] } }
    assert_equal [], clip.call(a - b) + ["--- the declared spelling only ---"] + clip.call(b - a), "Rust differs between the spellings" unless a == b
  end

  ROUTES = %(get "/a" do\n  json(a_room(id: 1))\nend\nget "/b" do\n  json(a_list)\nend\n)

  def plain(records) = records.map { |r| r.reject { |k, _| k == "line" } }

  # --- what is derived ---------------------------------------------------------------------------------------------

  def test_an_optional_single_row_derives_its_record
    read(source(A_ROOM, routes: %(get "/a" do\n  json(a_room(id: 1))\nend\n))) do |ir, _file|
      assert_equal [{ "name" => "RoomName", "kind" => "record",
                      "fields" => [{ "name" => "id", "type" => "i64" }, { "name" => "name", "type" => "string" }] }],
                   plain(ir["records"])
      q = ir["queries"].first
      assert_equal ["one", "RoomName", %w[id name], "opt<struct:RoomName>"], q.values_at("shape", "record", "fields", "rtype")
    end
  end

  def test_a_list_derives_its_record
    read(source(A_LIST, routes: %(get "/b" do\n  json(a_list)\nend\n))) do |ir, _file|
      assert_equal %w[RoomName], ir["records"].map { |r| r["name"] }
      q = ir["queries"].first
      assert_equal ["list", "RoomName", "list<struct:RoomName>"], q.values_at("shape", "record", "rtype")
    end
  end

  def test_the_fields_keep_the_selection_order_and_the_optionality
    decl = %(query :names, args: {}, returns: list(:RoomNames) do select(:name, :kind, :id) end\n)
    read(source(decl, routes: %(get "/n" do\n  json(names)\nend\n))) do |ir, _file|
      assert_equal [{ "name" => "name", "type" => "string", "optional" => true },
                    { "name" => "kind", "type" => "string" },
                    { "name" => "id", "type" => "i64" }], ir["records"].first["fields"]
    end
  end

  def test_two_queries_may_share_a_derived_record_that_selects_the_same_fields
    read(source(A_ROOM + A_LIST, routes: ROUTES)) do |ir, _file|
      assert_equal %w[RoomName], ir["records"].map { |r| r["name"] }
      assert_equal %w[RoomName RoomName], ir["queries"].map { |q| q["record"] }
    end
  end

  def test_a_derived_record_goes_where_the_record_block_would_be
    decl = %(query :ids, args: {}, returns: list(:RoomIds) do select(:id) end\n)
    before = "record :Before do\n  field :id, :i64\nend\n"
    after = "record :After do\n  field :id, :i64\nend\n"
    src = "#{HEAD}#{before}model :Room, table: :rooms do\n#{decl}end\n#{after}" +
          %(query :b, args: {}, returns: list(:Before), sql: "SELECT id FROM rooms"\nquery :a, args: {}, returns: list(:After), sql: "SELECT id FROM rooms"\n) +
          %(get "/i" do\n  json(ids)\nend\nget "/b" do\n  json(b)\nend\nget "/a" do\n  json(a)\nend\n)
    read(src) { |ir, _file| assert_equal %w[Before RoomIds After], ir["records"].map { |r| r["name"] } }
  end

  # --- the same artefacts as a declared record -----------------------------------------------------------------------

  def test_the_emitted_rust_is_the_declared_spellings
    derived = rust(source(A_ROOM + A_LIST, records: PADDING, routes: ROUTES))
    declared = rust(source(A_ROOM + A_LIST, records: DECLARED, routes: ROUTES))
    assert_includes derived, "struct RoomName {"
    assert_same_rust derived, declared
  end

  def test_the_startup_check_names_the_derived_records_fields
    rs = rust(source(A_ROOM, routes: %(get "/a" do\n  json(a_room(id: 1))\nend\n)))
    assert_includes rs, '&["id", "name"]'
  end

  def test_a_derived_record_is_used_by_a_handler_return_and_a_sql_query
    sql = %(query :by_sql, args: {}, returns: list(:RoomName), sql: "SELECT id, COALESCE(name, '') AS name FROM rooms"\n)
    routes = %(get "/a" do\n  json(a_room(id: 1))\nend\nget "/s" do\n  json(by_sql)\nend\n)
    read(source(A_ROOM + sql, routes: routes)) do |ir, _file|
      assert_equal %w[RoomName RoomName], ir["queries"].map { |q| q["record"] }
      assert_equal %w[RoomName], ir["records"].map { |r| r["name"] }
    end
  end

  # --- the rules that stay --------------------------------------------------------------------------------------------

  def test_a_declared_record_is_still_matched_not_derived
    wrong = "record :RoomName do\n  field :id, :i64\nend\n"
    error = refused(source(A_ROOM, records: wrong, routes: %(get "/a" do\n  json(a_room(id: 1))\nend\n)),
                    "the relation selects `name` (:string), which record `RoomName` does not have")
    assert_includes error.message, "query `a_room`"
  end

  def test_a_sql_query_never_derives
    decl = %(query :by_sql, args: {}, returns: list(:Nope), sql: "SELECT id FROM rooms"\n)
    refused(source(decl, routes: %(get "/s" do\n  json(by_sql)\nend\n)), "query `by_sql` returns record `Nope`, which is not declared")
  end

  def test_a_sql_query_may_not_promise_a_record_a_relation_derives_under_another_name
    decl = %(query :by_sql, args: {}, returns: list(:RoomNme), sql: "SELECT id FROM rooms"\n)
    refused(source(A_ROOM + decl, routes: %(get "/a" do\n  json(a_room(id: 1))\n  json(by_sql)\nend\n)),
            "query `by_sql` returns record `RoomNme`, which is not declared")
  end

  def test_two_relations_that_select_different_fields_conflict
    other = %(query :a_kind, args: {}, returns: list(:RoomName) do select(:id, :kind) end\n)
    error = refused(source(A_ROOM + other, routes: %(get "/a" do\n  json(a_room(id: 1))\n  json(a_kind)\nend\n)),
                    "query `a_kind` returns record `RoomName`, which query `a_room` derives from its own relation")
    assert_includes error.message, "field 2 is `name` (:string) in query `a_room` and `kind` (:string) here"
  end

  def test_the_conflict_covers_optionality_and_a_longer_selection
    optional = %(query :a_opt, args: {}, returns: list(:RoomName) do select(:id, :name) end\n)
    routes = %(get "/a" do\n  json(a_room(id: 1))\n  json(a_opt)\nend\n)
    refused(source(A_ROOM + optional, routes: routes), "field 2 is `name` (:string) in query `a_room` and `name` (:string?) here")
    longer = %(query :a_more, args: {}, returns: list(:RoomName) do select(:id, name: coalesce(:name, ""), kind: coalesce(:kind, "")) end\n)
    refused(source(A_ROOM + longer, routes: %(get "/a" do\n  json(a_room(id: 1))\n  json(a_more)\nend\n)),
            "field 3 is no field in query `a_room` and `kind` (:string) here")
  end
end
