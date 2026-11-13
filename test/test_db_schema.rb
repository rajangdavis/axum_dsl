# frozen_string_literal: true

# `table` (docs/database.md): a top-level declaration that fills the schema registry (Db::Schema) and emits nothing.
# Each case compiles a small DSL string; the refusals are pinned by test/refusals/table_*.rb. No cargo and no HTTP.
#
#   ruby -Ilib test/test_db_schema.rb
require "minitest/autorun"
require "tmpdir"
require "axum_dsl"

class TestDbSchema < Minitest::Test
  HEAD = <<~RB
    server "schema", version: "0.1.0"
    set :port, 8080
  RB

  ROUTE = %(get "/" do\n  text("hi")\nend\n)

  TABLES = <<~RB
    table :rooms do
      field :id, :i64
      field :name, :string, optional: true
      field :type, :string
    end

    table :messages do
      field :id, :i64
      field :room_id, :i64
      field :score, :f64
      field :pinned, :bool
    end
  RB

  def read(source)
    Dir.mktmpdir("schema") do |dir|
      file = File.join(dir, "schema.axum.rb")
      File.write(file, HEAD + source)
      yield AxumDsl.read(file), file
    end
  end

  def rust(source)
    read(source) { |ir, file| AxumDsl::Emit.files(ir, file)["src/main.rs"] }
  end

  # Each compile runs in its own temporary directory, and the generated Rust names the source file, so that
  # directory is taken out before comparing.
  def assert_same_rust(with, without)
    a = with.gsub(%r{/[^"\s]*/schema\.axum\.rb}, "schema.axum.rb").lines
    b = without.gsub(%r{/[^"\s]*/schema\.axum\.rb}, "schema.axum.rb").lines
    clip = ->(lines) { lines.first(8).map { |l| l.strip[0, 300] } }
    assert_equal [], clip.call(a - b) + ["--- without tables only ---"] + clip.call(b - a), "Rust differs with tables" unless a == b
  end

  def test_the_registry_holds_the_tables_and_their_columns_in_order
    read(TABLES + ROUTE) do |ir, _file|
      schema = AxumDsl::Db::Schema.from_ir(ir["tables"])
      assert_equal %w[rooms messages], schema.tables.keys
      assert_equal [{ name: "id", type: "i64", optional: false },
                    { name: "name", type: "string", optional: true },
                    { name: "type", type: "string", optional: false }], schema.columns("rooms")
      assert_equal({ name: "score", type: "f64", optional: false }, schema.column(:messages, :score))
      assert schema.table?("rooms")
    end
  end

  def test_an_unknown_table_or_column_is_nil
    read(TABLES + ROUTE) do |ir, _file|
      schema = AxumDsl::Db::Schema.from_ir(ir["tables"])
      assert_nil schema.column("rooms", "nope")
      assert_nil schema.column("nope", "id")
      assert_nil schema.columns("nope")
      refute schema.table?("nope")
    end
  end

  def test_a_file_without_tables_has_an_empty_registry
    read(ROUTE) { |ir, _file| assert_equal [], ir["tables"] }
  end

  def test_tables_emit_no_rust
    assert_same_rust rust(TABLES + ROUTE), rust(ROUTE)
  end

  def test_an_unused_table_is_not_refused
    read(TABLES + ROUTE) { |ir, _file| assert_equal 2, ir["tables"].size }
  end

  def test_a_model_may_declare_its_table
    read(%(model "Room" do\n  table :rooms do\n    field :id, :i64\n  end\nend\n) + ROUTE) do |ir, _file|
      assert_equal ["rooms"], ir["tables"].map { |t| t["name"] }
    end
  end
end
