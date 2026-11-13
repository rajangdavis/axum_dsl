# frozen_string_literal: true

# Time fields (docs/database.md, "Time fields"): a `:time` record or table field is a Rails timestamp stored as text and
# held as a String; a body reads it with to_fs(:number), iso8601, to_ms, to_s, == and !=. Each case compiles a small DSL
# string and asserts on the emitted Rust, or on the refusal. No cargo, no HTTP.
#
#   ruby -Ilib test/test_time_fields.rb
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "axum_dsl"

class TestTimeFields < Minitest::Test
  HEAD = <<~'RB'
    server "times", version: "0.1.0"
    set :port, 8080
    database :sqlite, path: "x.db"
  RB

  PLAIN = <<~'RB'
    record :SidebarUser do
      field :id, :i64
      field :name, :string
      field :updated_at, :time
    end
  RB

  ROW = <<~'RB'
    record :SidebarUser do
      field :id, :i64
      field :name, :string
      field :updated_at, :time

      def avatar_version = updated_at.to_fs(:number)
    end
  RB

  ROWS = %(query :sidebar_users, args: {}, returns: list(:SidebarUser), sql: "SELECT id, name, updated_at FROM users"\n)

  def route(expr) = %(get "/" do\n  text(sidebar_users.map { |r| #{expr} }.join(","))\nend\n)

  def compile(dsl)
    Dir.mktmpdir("times") do |dir|
      file = File.join(dir, "times.axum.rb")
      File.write(file, HEAD + dsl)
      AxumDsl::Emit.files(AxumDsl.read(file), file)["src/main.rs"]
    end
  end

  def refusal(dsl)
    assert_raises(AxumDsl::CompileError) { compile(dsl) }.message
  end

  def test_the_struct_field_is_a_string
    rs = compile(PLAIN + ROWS + route("r.name"))
    assert_includes rs, "updated_at: String,"
    assert_includes rs, 'updated_at: __r.get("updated_at")?'
  end

  def test_an_optional_time_is_an_optional_string
    row = PLAIN.sub("field :updated_at, :time", "field :updated_at, :time, optional: true")
    rs = compile(row + ROWS + route("r.name"))
    assert_includes rs, "updated_at: Option<String>,"
  end

  def test_to_fs_number_calls_its_helper
    rs = compile(PLAIN + ROWS + route("r.updated_at.to_fs(:number)"))
    assert_includes rs, "axum_dsl_time_number(&"
    assert_includes rs, "fn axum_dsl_time_number(t: &str) -> String {"
    refute_includes rs, "fn axum_dsl_time_iso8601"
    refute_includes rs, "fn axum_dsl_time_ms"
  end

  def test_iso8601_calls_its_helper
    rs = compile(PLAIN + ROWS + route("r.updated_at.iso8601"))
    assert_includes rs, "axum_dsl_time_iso8601(&"
    assert_includes rs, "fn axum_dsl_time_iso8601(t: &str) -> String {"
    refute_includes rs, "fn axum_dsl_time_number"
  end

  def test_to_ms_calls_its_helper
    rs = compile(PLAIN + ROWS + route("r.updated_at.to_ms.to_s"))
    assert_includes rs, "axum_dsl_time_ms(&"
    assert_includes rs, "fn axum_dsl_time_ms(t: &str) -> i64 {"
    refute_includes rs, "fn axum_dsl_time_iso8601"
  end

  def test_to_s_needs_no_helper
    rs = compile(PLAIN + ROWS + route("r.updated_at.to_s"))
    refute_includes rs, "fn axum_dsl_time_"
  end

  def test_equality_needs_no_helper
    rs = compile(PLAIN + ROWS + route("(r.updated_at == r.updated_at).to_s"))
    refute_includes rs, "fn axum_dsl_time_"
  end

  def test_a_record_method_uses_to_fs
    rs = compile(ROW + ROWS + route("r.avatar_version"))
    assert_includes rs, "fn avatar_version(&self) -> String {"
    assert_includes rs, "let updated_at = self.updated_at.clone();"
    assert_includes rs, "axum_dsl_time_number(&updated_at)"
    assert_includes rs, "fn axum_dsl_time_number(t: &str) -> String {"
  end

  def test_a_view_marker_prints_the_stored_text
    Dir.mktmpdir("times") do |dir|
      FileUtils.mkdir_p(File.join(dir, "views"))
      File.write(File.join(dir, "views", "home.html"), "{% for u in users %}{{ u.updated_at }}{% endfor %}")
      file = File.join(dir, "times.axum.rb")
      File.write(file, HEAD + PLAIN + ROWS + %(get "/" do\n  render :home, locals: { users: sidebar_users }\nend\n))
      rs = AxumDsl::Emit.files(AxumDsl.read(file), file)["src/main.rs"]
      assert_match(/u\.updated_at/, rs)
    end
  end

  STAMPS = <<~'RB'
    table :users do
      field :id, :i64
      field :updated_at, %<table>s
    end
    record :Stamp do
      field :id, :i64
      field :updated_at, %<record>s
    end
    model :User, table: :users do
      query :stamps, args: {}, returns: list(:Stamp) do select(:id, :updated_at) end
    end
  RB

  def stamps(table, record, expr)
    format(STAMPS, table: table, record: record) + %(get "/" do\n  text(stamps.map { |s| #{expr} }.join(","))\nend\n)
  end

  def test_a_relation_fills_a_time_record_field_from_a_time_column
    assert_includes compile(stamps(":time", ":time", "s.updated_at.to_fs(:number)")), "axum_dsl_time_number(&"
  end

  def test_a_string_record_field_is_filled_from_a_time_column
    assert_includes compile(stamps(":time", ":string", "s.updated_at")), "updated_at: String,"
  end

  def test_a_time_record_field_is_filled_from_a_string_column
    assert_includes compile(stamps(":string", ":time", "s.updated_at.iso8601")), "axum_dsl_time_iso8601(&"
  end

  def test_an_unsupported_method_is_refused_with_the_list
    msg = refusal(PLAIN + ROWS + route("r.updated_at.strftime"))
    assert_includes msg, "unsupported method `strftime` on a time"
    assert_includes msg, "to_fs(:number), iso8601, to_ms, to_s, == and !="
  end

  def test_to_fs_takes_only_number
    msg = refusal(PLAIN + ROWS + route("r.updated_at.to_fs(:db)"))
    assert_includes msg, "`to_fs` on a time takes `:number`"
  end

  def test_time_is_not_an_args_type
    msg = refusal(PLAIN + %(query :q, args: { at: :time }, returns: list(:SidebarUser), sql: "SELECT id, name, updated_at FROM users WHERE updated_at > :at"\n) +
                  %(get "/" do\n  text("x")\nend\n))
    assert_includes msg, "time"
  end

  def test_time_is_not_a_params_field
    msg = refusal(%(params :P do\n  field :at, :time\nend\n) + PLAIN + ROWS + route("r.name"))
    assert_includes msg, "`:time` is a column type of a `record` or a `table`"
  end
end
