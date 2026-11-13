# frozen_string_literal: true

# `destroy` as a relation terminal (docs/database.md, "Queries as relations"): an `execute` ending in `destroy` is the
# ordered DELETEs of Db::Rel.destroy for the model's `dependent:` associations, run as one unit inside a `transaction`.
# Pinned here by the exact SQL, the notice, the Rust the statement becomes and the call-site rule; the refusals are
# also test/refusals/destroy_*.rb. No cargo and no HTTP.
#
#   ruby -Ilib test/test_db_destroy.rb
require "minitest/autorun"
require "tmpdir"
require "axum_dsl"

class TestDbDestroy < Minitest::Test
  HEAD = <<~RB
    server "destroy", version: "0.1.0"
    set :port, 8080
    database :sqlite, path: "x.db"
  RB

  TABLES = <<~RB
    table :rooms do
      field :id, :i64
      field :name, :string, optional: true
    end

    table :memberships do
      field :id, :i64
      field :room_id, :i64
    end

    table :messages do
      field :id, :i64
      field :room_id, :i64
    end

    table :boosts do
      field :id, :i64
      field :message_id, :i64
    end

    table :action_text_rich_texts do
      field :id, :i64
      field :record_type, :string
      field :record_id, :i64
    end

    table :active_storage_attachments do
      field :id, :i64
      field :record_type, :string
      field :record_id, :i64
    end

    table :message_search_index do
      field :rowid, :i64
      field :body, :string
    end

    table :notes do
      field :id, :i64
    end
  RB

  # `Note` has no `dependent:`, so its destroy is the one DELETE; it is declared first, so it is statement 0.
  MODELS = <<~RB
    model :Membership, table: :memberships do
    end

    model :Note, table: :notes do
      execute :drop_note, args: { id: :i64 } do where(id: arg(:id)).destroy end
    end

    model :Message, table: :messages do
      has_many :boosts, dependent: :delete_all
      has_many :rich_texts, table: :action_text_rich_texts, as: :record, dependent: :delete_all
      has_many :attachments, table: :active_storage_attachments, as: :record, dependent: :delete_all
      has_one :search_row, table: :message_search_index, foreign_key: :rowid, dependent: :delete_all
      belongs_to :room, model: :Room
    end
  RB

  # The statements of the Room example in test/test_db_rel.rb, with the argument called `id`.
  ROOM_SQLS = [
    "DELETE FROM boosts WHERE message_id IN (SELECT id FROM messages WHERE room_id = :id)",
    "DELETE FROM action_text_rich_texts WHERE record_type = 'Message' AND record_id IN (SELECT id FROM messages WHERE room_id = :id)",
    "DELETE FROM active_storage_attachments WHERE record_type = 'Message' AND record_id IN (SELECT id FROM messages WHERE room_id = :id)",
    "DELETE FROM message_search_index WHERE rowid IN (SELECT id FROM messages WHERE room_id = :id)",
    "DELETE FROM messages WHERE room_id = :id",
    "DELETE FROM memberships WHERE room_id = :id",
    "DELETE FROM rooms WHERE id = :id"
  ].freeze

  DESTROY_ROOM = "execute :destroy_room, args: { id: :i64 } do where(id: arg(:id)).destroy end\n"
  ROOM_COUNT = "query :room_count, args: {}, returns: :i64 do count end\n"

  IN_TX = %(post "/destroy" do\n  rows = transaction do\n    destroy_room(id: 1)\n  end\n  text(rows.to_s)\nend\n)
  COUNT = %(get "/count" do\n  room_count.to_s\nend\n)
  DROP = %(post "/drop" do\n  drop_note(id: 1).to_s\nend\n)

  def room(statements)
    "model :Room, table: :rooms do\n  has_many :messages, dependent: :destroy\n  has_many :memberships, dependent: :delete_all\n#{statements}end\n"
  end

  # The route that calls `drop_note` is always there, so no case trips the unused-statement check.
  def source(statements, routes: "")
    "#{HEAD}#{TABLES}#{MODELS}#{room(statements)}#{routes}#{DROP}"
  end

  def read(src)
    Dir.mktmpdir("destroy") do |dir|
      file = File.join(dir, "destroy.axum.rb")
      File.write(file, src)
      yield AxumDsl.read(file), file
    end
  end

  def rust(src)
    read(src) { |ir, file| AxumDsl::Emit.files(ir, file)["src/main.rs"] }
  end

  def refused(src, text)
    Dir.mktmpdir("destroy") do |dir|
      file = File.join(dir, "destroy.axum.rb")
      File.write(file, src)
      error = assert_raises(AxumDsl::CompileError) { AxumDsl.read(file) }
      assert_includes error.message, text
      error
    end
  end

  # --- the statements -------------------------------------------------------------------------------------------------

  def test_the_destroy_is_the_ordered_deletes_of_the_dependent_tree
    read(source(DESTROY_ROOM, routes: IN_TX)) do |ir, _file|
      room = ir["queries"].find { |q| q["name"] == "destroy_room" }
      assert_equal ROOM_SQLS, room["sqls"]
      assert_equal "DELETE FROM rooms WHERE id = :id", room["sql"]
      assert_equal %w[execute execute i64], room.values_at("kind", "shape", "rtype")
    end
  end

  def test_a_model_without_dependents_destroys_with_the_one_delete_and_may_be_called_anywhere
    read(source(DESTROY_ROOM, routes: IN_TX)) do |ir, _file|
      note = ir["queries"].find { |q| q["name"] == "drop_note" }
      assert_equal "DELETE FROM notes WHERE id = :id", note["sql"]
      refute note.key?("sqls"), "one DELETE is an ordinary statement"
    end
  end

  def test_the_notice_lists_the_statements_in_order
    AxumDsl::Notify.reset!
    read(source(DESTROY_ROOM, routes: IN_TX)) { |_ir, _file| }
    notes = AxumDsl::Notify.notes.select { |n| n.code == "N-DESTROY" }
    assert_equal 1, notes.size, "one notice, for the statement with dependents; none for drop_note"
    assert_equal :notice, notes.first.level
    message = notes.first.message
    assert_includes message, "execute `destroy_room` destroys the row and what depends on it with 7 statements"
    ROOM_SQLS.each_with_index { |sql, i| assert_includes message, "#{i + 1}. #{sql}" }
    assert_operator message.index("1. DELETE FROM boosts"), :<, message.index("7. DELETE FROM rooms")
  end

  # --- the Rust --------------------------------------------------------------------------------------------------------

  def test_the_emitted_rust_runs_the_statements_in_order_on_the_transactions_connection
    rs = rust(source(DESTROY_ROOM, routes: IN_TX))
    ROOM_SQLS.each_with_index { |sql, i| assert_includes rs, "const DB_SQL_DESTROY_ROOM_#{i + 1}: &str = #{AxumDsl.rstr(sql)};" }
    core = rs[/fn query_destroy_room_on\(.*?\n\}\n/m]
    refute_nil core
    at = (1..7).map { |i| core.index("prepare_cached(DB_SQL_DESTROY_ROOM_#{i})") }
    refute_includes at, nil
    assert_equal at.sort, at, "prepared and run in the order of the list"
    assert_equal 6, core.scan("__stmt.execute(rusqlite::named_params! { \":id\": id })?;").size, "six run for their effect"
    assert_includes core, "let __out = __stmt.execute(rusqlite::named_params! { \":id\": id }).map(|__n| __n as i64);"
    assert_match(/db_tx\("transaction", move \|__tx\| \{[^}]*query_destroy_room_on\(__tx, [^)]*\)\?/, rs)
    refute_includes rs, "async fn query_destroy_room(", "a destroy has no pooled wrapper: it only runs in a transaction"
  end

  def test_schema_check_prepares_every_generated_statement
    rs = rust(source(DESTROY_ROOM + ROOM_COUNT, routes: IN_TX + COUNT))
    rows = rs.scan(/\("destroy_room", "[^"]+", (DB_SQL_DESTROY_ROOM_\d), 0, &\[\]\),/).flatten
    assert_equal((1..7).map { |i| "DB_SQL_DESTROY_ROOM_#{i}" }, rows)
    assert_includes rs, "for &(__name, __at, __sql, __check, __fields) in DB_STATEMENTS {\n        let __stmt = __c.prepare(__sql)"
  end

  def test_the_statement_after_a_destroy_keeps_its_row_in_the_writes_table
    rs = rust(source(DESTROY_ROOM + ROOM_COUNT, routes: IN_TX + COUNT))
    assert_includes rs, 'db_run(8, "room_count"', "drop_note is row 0 and destroy_room rows 1 to 7"
  end

  # --- the call site and the chain -----------------------------------------------------------------------------------------

  def test_calling_it_outside_a_transaction_is_refused_with_the_spelling
    error = refused(source(DESTROY_ROOM, routes: %(post "/destroy" do\n  text(destroy_room(id: 1).to_s)\nend\n)),
                    "execute `destroy_room` destroys a row and what depends on it with 7 statements that must run as one unit, " \
                    "so it is called inside a transaction: `transaction do destroy_room(id: ...) end`")
    assert_includes error.message, "N-DESTROY"
  end

  def test_a_bare_call_outside_a_transaction_is_refused_too
    refused(source(DESTROY_ROOM, routes: %(post "/destroy" do\n  destroy_room(id: 1)\n  text("ok")\nend\n)), "so it is called inside a transaction")
  end

  def test_destroy_takes_no_arguments_so_returning_is_not_there
    refused(source("execute :destroy_room, args: { id: :i64 } do where(id: arg(:id)).destroy(returning: :id) end\n"), "`destroy` takes no arguments")
  end

  def test_destroy_is_a_write_so_a_query_refuses_it
    refused(source("query :gone, args: { id: :i64 }, returns: :i64 do where(id: arg(:id)).destroy end\n"), "`destroy` changes data, so it belongs in an `execute`")
  end

  def test_a_destroy_with_a_join_is_refused
    refused(source("execute :destroy_room, args: { id: :i64 } do joins(:memberships).where(id: arg(:id)).destroy end\n"), "a destroy can not have joins")
  end
end
