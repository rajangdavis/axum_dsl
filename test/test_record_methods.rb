# frozen_string_literal: true

# Record methods (docs/database.md, "Record methods"): a `def` in a `record` block is a method of the row, read like a
# field in a body and in a view. Each case compiles a small DSL string beside a view and asserts on the emitted Rust,
# or on the refusal. No cargo, no HTTP.
#
#   ruby -Ilib test/test_record_methods.rb
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "axum_dsl"

class TestRecordMethods < Minitest::Test
  HEAD = <<~'RB'
    server "methods", version: "0.1.0"
    set :port, 8080
    database :sqlite, path: "x.db"
  RB

  ROW = <<~'RB'
    record :BoostRow do
      field :id, :i64
      field :booster_name, :string
      field :content, :string

      def label = "#{booster_name} boosted #{content}"
      def first_name
        booster_name.split.first || ""
      end
      def title = "#{first_name}: #{content}"
    end
  RB

  ROWS = %(query :boost_rows, args: {}, returns: list(:BoostRow), sql: "SELECT id, booster_name, content FROM boosts"\n)
  HOME_ROUTE = %(get "/" do\n  render :home, locals: { rows: boost_rows }\nend\n)
  TITLES_ROUTE = <<~'RB'
    get "/titles" do
      rows = boost_rows
      text(rows.map { |r| r.title }.join(", "))
    end
  RB
  ROUTES = HOME_ROUTE + TITLES_ROUTE
  HOME = "{% for b in rows %}[{{ b.label }}]{% endfor %}"

  def compile(dsl, home: HOME)
    Dir.mktmpdir("methods") do |dir|
      FileUtils.mkdir_p(File.join(dir, "views"))
      File.write(File.join(dir, "views", "home.html"), home)
      file = File.join(dir, "methods.axum.rb")
      File.write(file, HEAD + dsl)
      AxumDsl::Emit.files(AxumDsl.read(file), file)["src/main.rs"]
    end
  end

  def refusal(dsl, home: HOME)
    assert_raises(AxumDsl::CompileError) { compile(dsl, home: home) }.message
  end

  def test_a_method_is_a_function_of_the_row_struct
    rs = compile(ROW + ROWS + ROUTES)
    assert_includes rs, "impl BoostRow {"
    assert_includes rs, "fn label(&self) -> String {"
    assert_includes rs, "fn first_name(&self) -> String {"
    assert_includes rs, "let booster_name = self.booster_name.clone();"
    assert_includes rs, "let content = self.content.clone();"
  end

  def test_a_method_reads_another_by_calling_it
    rs = compile(ROW + ROWS + ROUTES)
    assert_includes rs, "fn title(&self) -> String {"
    assert_includes rs, "let first_name = self.first_name();"
  end

  def test_every_method_carries_the_dead_code_allowance
    rs = compile(ROW + ROWS + ROUTES)
    assert_includes rs, "#[allow(dead_code)]"
    assert_includes rs, "fn label(&self) -> String {"
  end

  def test_a_body_reads_a_method_like_a_field
    rs = compile(ROW + ROWS + ROUTES)
    assert_match(/\.title\(\)/, rs)
  end

  def test_a_view_reads_a_method_of_a_loop_variable
    rs = compile(ROW + ROWS + ROUTES)
    assert_match(/b\.label\(\)/, rs)
  end

  def test_a_view_condition_reads_a_bool_method
    row = "record :BoostRow do\n  field :id, :i64\n  field :content, :string\n  def blank = content.empty?\nend\n"
    rs = compile(row + ROWS.sub("id, booster_name, content", "id, content") + HOME_ROUTE,
                 home: "{% for b in rows %}{% if b.blank %}blank{% endif %}{% endfor %}")
    assert_match(/b\.blank\(\)/, rs)
  end

  def test_a_nilable_field_is_nilable_in_a_method
    row = "record :BoostRow do\n  field :id, :i64\n  field :note, :string, optional: true\n  def shown = note || \"none\"\nend\n"
    rs = compile(row + ROWS.sub("id, booster_name, content", "id, note") + %(get "/" do\n  text(boost_rows.map { |r| r.shown }.join(","))\nend\n), home: "")
    assert_includes rs, "fn shown(&self) -> String {"
  end

  def test_a_def_with_parameters_is_refused
    row = ROW.sub('def label = "#{booster_name} boosted #{content}"', "def label(prefix) = prefix")
    msg = refusal(row + ROWS + ROUTES)
    assert_includes msg, "parameters are not supported on record methods yet"
  end

  def test_a_name_is_a_field_or_a_def_never_both
    row = ROW.sub("def label =", "def content =")
    msg = refusal(row + ROWS + ROUTES)
    assert_includes msg, "a name is a field or a def, never both"
  end

  def test_two_defs_of_one_name_are_refused
    row = ROW.sub("def title =", "def label =")
    msg = refusal(row + ROWS + ROUTES)
    assert_includes msg, "duplicate def `label`"
  end

  def test_a_statement_call_in_a_method_is_refused
    count = %(query :count_all, args: {}, returns: :i64, sql: "SELECT COUNT(*) FROM boosts"\n)
    row = ROW.sub("def title =", "def total = count_all\n  def title =")
    msg = refusal(count + row + ROWS + ROUTES)
    assert_includes msg, "cannot use a statement call (`count_all`)"
    assert_includes msg, "a record method is pure"
  end

  def test_current_in_a_method_is_refused
    row = ROW.sub("def title =", "def who = current(:user)\n  def title =")
    msg = refusal(row + ROWS + ROUTES)
    assert_includes msg, "cannot use `current`"
  end

  def test_a_method_cannot_recurse_directly
    row = ROW.sub("def title =", "def again = again\n  def title =")
    msg = refusal(row + ROWS + ROUTES)
    assert_includes msg, "reaches itself (again -> again)"
  end

  def test_a_method_cannot_recurse_through_another
    row = ROW.sub("def title =", "def ping = pong\n  def pong = ping\n  def title =")
    msg = refusal(row + ROWS + ROUTES)
    assert_includes msg, "reaches itself (ping -> pong -> ping)"
  end

  def test_json_of_a_record_leaves_methods_out
    rs = compile(ROW + ROWS + %(get "/" do\n  json(boost_rows)\nend\n), home: "")
    assert_includes rs, "struct BoostRow {"
    refute_includes rs, "label: String,"
  end

  def test_the_startup_column_check_ignores_methods
    rs = compile(ROW + ROWS + ROUTES)
    assert_match(/\("boost_rows", .*, 2, &\["id", "booster_name", "content"\]\)/, rs)
  end
end
