# frozen_string_literal: true

# A record's list field (`field :boosts, list(:Boost), from: :boosts_of`, docs/database.md "A list inside a record"):
# the query named by `from:` runs once per row, its arguments the row's columns of the same names. Each case
# compiles a small DSL string beside a view and asserts on the emitted Rust, or on the refusal. No cargo, no HTTP.
#
#   ruby -Ilib test/test_record_lists.rb
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "axum_dsl"

class TestRecordLists < Minitest::Test
  HEAD = <<~RB
    server "lists", version: "0.1.0"
    set :port, 8080
    database :sqlite, path: "x.db"
  RB

  BOOST = <<~RB
    record :Boost do
      field :id, :i64
      field :content, :string
    end
  RB

  MESSAGE = <<~RB
    record :Message do
      field :id, :i64
      field :boosts, list(:Boost), from: :boosts_of
    end
  RB

  BOOSTS_OF = %(query :boosts_of, args: { id: :i64 }, returns: list(:Boost), sql: "SELECT id, content FROM boosts WHERE message_id = :id"\n)
  MESSAGES = %(query :messages, args: {}, returns: list(:Message), sql: "SELECT id FROM messages"\n)
  ROUTE = %(get "/" do\n  render :home, locals: { messages: messages }\nend\n)
  HOME = "{% for m in messages %}{% for b in m.boosts %}[{{ b.content }}]{% endfor %}{% endfor %}"

  def compile(dsl, home: HOME)
    Dir.mktmpdir("lists") do |dir|
      FileUtils.mkdir_p(File.join(dir, "views"))
      File.write(File.join(dir, "views", "home.html"), home)
      file = File.join(dir, "lists.axum.rb")
      File.write(file, HEAD + dsl)
      AxumDsl::Emit.files(AxumDsl.read(file), file)["src/main.rs"]
    end
  end

  def refusal(dsl, home: HOME)
    assert_raises(AxumDsl::CompileError) { compile(dsl, home: home) }.message
  end

  def test_the_struct_holds_a_vec_and_from_row_leaves_it_empty
    rs = compile(BOOST + MESSAGE + BOOSTS_OF + MESSAGES + ROUTE)
    assert_includes rs, "boosts: Vec<Boost>,"
    assert_includes rs, "Message { id: __r.get(\"id\")?, boosts: Vec::new() }"
  end

  def test_the_statement_fills_each_row_from_the_sub_query_on_the_same_connection
    rs = compile(BOOST + MESSAGE + BOOSTS_OF + MESSAGES + ROUTE)
    assert_includes rs, "for __row in __out.iter_mut() {"
    assert_includes rs, "__row.boosts = query_boosts_of_on(__c, __row.id)?;"
  end

  def test_a_sub_query_no_body_calls_gets_no_pooled_wrapper
    rs = compile(BOOST + MESSAGE + BOOSTS_OF + MESSAGES + ROUTE)
    refute_includes rs, "async fn query_boosts_of("
    assert_includes rs, "async fn query_messages("
  end

  def test_the_startup_check_leaves_the_list_field_out_of_the_columns
    rs = compile(BOOST + MESSAGE + BOOSTS_OF + MESSAGES + ROUTE)
    assert_match(/\("messages", .*, 2, &\["id"\]\)/, rs)
  end

  def test_a_one_row_query_fills_its_record_too
    one = %(query :first_message, args: {}, returns: :Message?, sql: "SELECT id FROM messages LIMIT 1"\n)
    rs = compile(BOOST + MESSAGE + BOOSTS_OF + one + %(get "/" do\n  json(first_message)\nend\n), home: "")
    assert_includes rs, "if let Some(__row) = __out.as_mut() {"
  end

  def test_a_string_argument_is_cloned_for_the_sub_query
    boost = BOOST
    message = "record :Message do\n  field :id, :i64\n  field :slug, :string\n  field :boosts, list(:Boost), from: :boosts_of\nend\n"
    boosts_of = %(query :boosts_of, args: { slug: :string }, returns: list(:Boost), sql: "SELECT id, content FROM boosts WHERE slug = :slug"\n)
    messages = %(query :messages, args: {}, returns: list(:Message), sql: "SELECT id, slug FROM messages"\n)
    rs = compile(boost + message + boosts_of + messages + ROUTE)
    assert_includes rs, "query_boosts_of_on(__c, __row.slug.clone())?"
  end

  def test_a_list_field_needs_from
    msg = refusal(BOOST + "record :Message do\n  field :id, :i64\n  field :boosts, list(:Boost)\nend\n" + BOOSTS_OF + MESSAGES + ROUTE)
    assert_includes msg, "name the query that fills it"
  end

  def test_from_on_a_column_is_refused
    msg = refusal(BOOST + "record :Message do\n  field :id, :i64, from: :boosts_of\nend\n" + BOOSTS_OF + MESSAGES + ROUTE)
    assert_includes msg, "`from:` fills a list field"
  end

  def test_the_sub_query_must_exist
    msg = refusal(BOOST + MESSAGE + MESSAGES + ROUTE)
    assert_includes msg, "`from: :boosts_of`, which is not a query"
  end

  def test_the_sub_query_must_return_the_list
    wrong = %(query :boosts_of, args: { id: :i64 }, returns: :i64, sql: "SELECT COUNT(*) FROM boosts WHERE message_id = :id"\n)
    msg = refusal(BOOST + MESSAGE + wrong + MESSAGES + ROUTE)
    assert_includes msg, "must return list(:Boost)"
  end

  def test_a_sub_query_argument_must_be_a_column_of_the_row
    other = %(query :boosts_of, args: { message_id: :i64 }, returns: list(:Boost), sql: "SELECT id, content FROM boosts WHERE message_id = :message_id"\n)
    msg = refusal(BOOST + MESSAGE + other + MESSAGES + ROUTE)
    assert_includes msg, "has no such column"
  end

  def test_a_sub_query_argument_must_have_the_columns_type
    other = %(query :boosts_of, args: { id: :string }, returns: list(:Boost), sql: "SELECT id, content FROM boosts WHERE slug = :id"\n)
    msg = refusal(BOOST + MESSAGE + other + MESSAGES + ROUTE)
    assert_includes msg, "takes `id` as :string, but the column `id` is :i64"
  end

  def test_the_element_record_has_no_list_fields_of_its_own
    nested = "record :Boost do\n  field :id, :i64\n  field :subs, list(:Boost), from: :boosts_of\nend\n"
    msg = refusal(nested + MESSAGE + BOOSTS_OF.sub("SELECT id, content", "SELECT id") + MESSAGES + ROUTE)
    assert_includes msg, "has list fields of its own"
  end

  def test_params_do_not_take_from
    msg = refusal(BOOST + MESSAGE + BOOSTS_OF + MESSAGES + "params :P do\n  field :x, :string, from: :boosts_of\nend\n" + ROUTE)
    assert_includes msg, "`from:` fills a list field of a `record`"
  end

  def test_a_view_may_loop_over_the_list_field_through_a_partial
    partial = "{% args boosts: %}{% for b in boosts %}<{{ b.content }}>{% endfor %}"
    home = "{% for m in messages %}{{ partial :inner, boosts: m.boosts }}{% endfor %}"
    Dir.mktmpdir("lists") do |dir|
      FileUtils.mkdir_p(File.join(dir, "views"))
      File.write(File.join(dir, "views", "home.html"), home)
      File.write(File.join(dir, "views", "inner.html"), partial)
      file = File.join(dir, "lists.axum.rb")
      File.write(file, HEAD + BOOST + MESSAGE + BOOSTS_OF + MESSAGES + ROUTE)
      rs = AxumDsl::Emit.files(AxumDsl.read(file), file)["src/main.rs"]
      assert_match(/for __it_b in &[^{]*boosts/, rs)
    end
  end
end
