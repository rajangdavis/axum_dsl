# frozen_string_literal: true

# The typed console (docs/console.md): the line checker and the REPL against a stand-in binary that speaks the wire
# protocol, the Rust the compiler emits for `--console`, and (when cargo and the sqlite3 command are there) the real
# thing end to end on examples/notes.axum.rb. The end-to-end cases build a crate, so they are skipped without cargo.
#
#   ruby -Ilib test/test_console.rb
require "minitest/autorun"
require "json"
require "open3"
require "rbconfig"
require "stringio"
require "tmpdir"
require "axum_dsl"

class TestConsole < Minitest::Test
  EXE = File.expand_path("../exe/axum_dsl", __dir__)
  NOTES = File.expand_path("../examples/notes.axum.rb", __dir__)

  def ir = (@ir ||= AxumDsl.read(NOTES))

  def catalog = AxumDsl::Console::Catalog.new(ir)

  def refusal(text)
    name, args = AxumDsl::Console::Line.parse(text)
    assert_raises(AxumDsl::Console::Refused) { catalog.check(name, args) }.message
  end

  # --- the line --------------------------------------------------------------------------------------------------

  def test_a_line_is_a_call_with_literal_arguments
    parse = ->(text) { AxumDsl::Console::Line.parse(text) }
    assert_equal ["recent_notes", { "limit" => 5 }], parse.call("recent_notes(limit: 5)")
    assert_equal ["recent_notes", { "limit" => 5 }], parse.call("recent_notes limit: 5")
    assert_equal ["find_note", { "id" => -3 }], parse.call("q :find_note, id: -3")
    assert_equal ["add_note", { "body" => "a\nb" }], parse.call('add_note(body: "a\nb")')
    assert_equal ["x", { "a" => 1.5, "b" => true, "c" => nil }], parse.call("x(a: 1.5, b: true, c: nil)")
    assert_equal ["recent_notes", {}], parse.call("recent_notes")
  end

  def test_a_line_that_is_not_a_literal_call_is_refused_not_evaluated
    ["system(\"ls\")", "recent_notes(limit: 1 + 1)", "recent_notes(limit: foo)", "Kernel.exit", "a; b", "recent_notes(limit:"].each do |text|
      assert_raises(AxumDsl::Console::Refused, text) { AxumDsl::Console::Line.parse(text) }
    end
  end

  # --- the compiler's checks, before anything is sent ------------------------------------------------------------

  def test_an_unknown_query_suggests_the_declared_name
    assert_includes refusal("recent_note(limit: 5)"), "no query `recent_note`; did you mean `recent_notes`?"
  end

  def test_an_argument_is_checked_against_its_declared_type
    message = refusal('recent_notes(limit: "ten")')
    assert_includes message, "argument `limit` of `recent_notes` is i64, got \"ten\" (String)"
    assert_includes refusal("recent_notes(limit: 1.5)"), "is i64"
    assert_includes refusal("recent_notes"), "`recent_notes` needs `limit: i64`"
  end

  def test_an_unknown_argument_suggests_the_declared_one
    message = refusal("recent_notes(limt: 5)")
    assert_includes message, "no argument `limt`"
    assert_includes message, "did you mean `limit`?"
    assert_includes message, "it takes limit: i64"
  end

  def test_an_execute_is_refused_as_a_write
    assert_includes refusal("delete_note(id: 1)"), "it writes, and the console is read-only"
  end

  def test_the_catalog_knows_the_declared_row_types
    queries = catalog.queries.to_h { |q| [q.name, q] }
    assert_equal "[{id: i64, body: string, created_at: string, tag: string?}]", queries["recent_notes"].row_type
    assert_equal "{id: i64, body: string, created_at: string, tag: string?}?", queries["find_note"].row_type
    assert_equal "i64", queries["add_note"].row_type
    assert_equal "recent_notes(limit: i64)", queries["recent_notes"].signature
  end

  # --- the REPL against a stand-in binary ------------------------------------------------------------------------

  # A script that speaks the console protocol: a ready line, then one canned table for any request.
  STAND_IN = <<~'RB'
    require "json"
    abort "stand-in: no database" unless ARGV == ["--console", ARGV[1]] && File.file?(ARGV[1])
    $stdout.sync = true
    puts JSON.generate("ready" => true, "statements" => 1)
    $stdin.each_line do |line|
      request = JSON.parse(line)
      if request["stmt"] == "boom"
        puts JSON.generate("error" => "statement `boom` writes, and the console is read-only")
      else
        rows = (1..25).map { |i| [i, i.odd? ? nil : "note #{i}", request["args"]["limit"]] }
        puts JSON.generate("columns" => %w[id body limit], "rows" => rows, "ms" => 0.25, "echo" => request)
      end
    end
  RB

  def with_stand_in
    Dir.mktmpdir("console") do |dir|
      script = File.join(dir, "stand_in")
      File.write(script, "#!#{RbConfig.ruby}\n#{STAND_IN}")
      File.chmod(0o755, script)
      db = File.join(dir, "x.db")
      File.write(db, "")
      yield script, db
    end
  end

  def test_the_child_encodes_one_request_line_and_decodes_one_response_line
    with_stand_in do |script, db|
      child = AxumDsl::Console::Child.new(script, db)
      reply = child.call("recent_notes", { "limit" => 7 })
      assert_equal({ "stmt" => "recent_notes", "args" => { "limit" => 7 } }, reply["echo"])
      assert_equal %w[id body limit], reply["columns"]
      assert_equal [1, nil, 7], reply["rows"].first
      assert_equal "statement `boom` writes, and the console is read-only", child.call("boom", {})["error"]
      child.close
    end
  end

  def test_a_binary_that_refuses_to_start_reports_why
    with_stand_in do |script, db|
      error = assert_raises(AxumDsl::Console::Refused) { AxumDsl::Console::Child.new(script, "#{db}.missing") }
      assert_includes error.message, "no database"
    end
  end

  def test_a_query_prints_the_sql_the_row_type_a_page_of_rows_and_the_count
    with_stand_in do |script, db|
      out = StringIO.new
      child = AxumDsl::Console::Child.new(script, db)
      repl = AxumDsl::Console::Repl.new(catalog, child: child, out: out)
      assert repl.handle("recent_notes(limit: 3)")
      text = out.string
      assert_includes text, "SELECT id, body, created_at, tag FROM notes ORDER BY id DESC LIMIT :limit"
      assert_includes text, "=> [{id: i64, body: string, created_at: string, tag: string?}]"
      assert_match(/^id  body\s+limit$/, text)
      assert_includes text, "NULL"
      assert_includes text, "25 rows, 0.25 ms (5 more: .more)"
      assert_equal 20, text.lines.count { |l| l.chomp.match?(/\A\s*\d+\s+(NULL|note \d+)\s+3\z/) }
      out.truncate(0)
      out.rewind
      repl.handle(".more")
      assert_includes out.string, "25 rows, 0.25 ms"
      refute_includes out.string, "more: .more"
      assert_equal 5, out.string.lines.count { |l| l.chomp.match?(/\A\s*\d+\s+(NULL|note \d+)\s+3\z/) }
      child.close
    end
  end

  def test_a_refused_line_sends_nothing_and_the_error_is_printed
    child = Object.new
    child.define_singleton_method(:call) { |*| raise "sent" }
    out = StringIO.new
    repl = AxumDsl::Console::Repl.new(catalog, child: child, out: out)
    repl.handle('recent_notes(limit: "x")')
    repl.handle("recent_note(limit: 1)")
    assert_includes out.string, "error: argument `limit`"
    assert_includes out.string, "did you mean `recent_notes`?"
  end

  def test_the_meta_commands
    out = StringIO.new
    graph = AxumDsl::TypeGraph.new
    AxumDsl.read(NOTES, graph: graph)
    repl = AxumDsl::Console::Repl.new(catalog, child: nil, graph: graph, out: out)
    repl.banner
    assert_includes out.string, AxumDsl::Console::BANNER
    out.truncate(0)
    out.rewind
    repl.handle(".queries")
    assert_includes out.string, "recent_notes(limit: i64) -> [{id: i64"
    assert_includes out.string, "delete_note(id: i64) -> i64 (rows changed)  (write: not available here)"
    out.truncate(0)
    out.rewind
    repl.handle(".sql find_note")
    assert_equal "SELECT id, body, created_at, tag FROM notes WHERE id = :id\n", out.string
    out.truncate(0)
    out.rewind
    repl.handle(".sql find_not")
    assert_includes out.string, "did you mean `find_note`?"
    out.truncate(0)
    out.rewind
    repl.handle(".why nope:x")
    assert_includes out.string, "error: no node `nope:x`"
    out.truncate(0)
    out.rewind
    refute repl.handle(".quit")
  end

  # --- the Rust the compiler emits ------------------------------------------------------------------------------

  def rust = AxumDsl::Emit.files(ir, NOTES)["src/main.rs"]

  def test_main_is_gated_on_the_console_flag_like_schema_check
    assert_includes rust, 'if std::env::args().nth(1).as_deref() == Some("--console") {'
    assert_operator rust.index('Some("--console")'), :<, rust.index("db_open().await")
  end

  def test_the_console_is_query_only_refuses_writes_and_pending_migrations
    assert_includes rust, 'c.pragma_update(None, "query_only", true)'
    assert_includes rust, "if !probe.readonly() {"
    assert_includes rust, "writes, and the console is read-only"
    assert_includes rust, "has migrations that are not applied"
    assert_includes rust, "for &(file, sha, _) in DB_MIGRATIONS {"
  end

  def test_an_app_without_migrations_has_no_migration_check
    source = <<~RB
      server "c", version: "0.1.0"
      set :port, 8080
      database :sqlite, path: "x.db"
      record :Row do
        field :n, :i64
      end
      query :one, args: {}, returns: list(:Row), sql: "SELECT 1 AS n"
      get "/n" do
        json(one)
      end
    RB
    Dir.mktmpdir("console") do |dir|
      file = File.join(dir, "c.axum.rb")
      File.write(file, source)
      main = AxumDsl::Emit.files(AxumDsl.read(file), file)["src/main.rs"]
      assert_includes main, "fn db_console("
      refute_includes main, "db_console_applied"
      refute_includes main, "DB_MIGRATIONS"
    end
  end

  # --- end to end -----------------------------------------------------------------------------------------------

  def tool?(*cmd) = system(*cmd, out: File::NULL, err: File::NULL)

  # notes.sqlite3 as the server would leave it: the migrations applied and recorded, one note.
  def seed(db)
    sql = ir["migrations"]["files"].map do |m|
      "#{m['sql']}\nINSERT INTO axum_dsl_migrations (version, sha256, applied_at) VALUES ('#{m['file']}', '#{m['sha256']}', datetime('now'));"
    end
    sql.unshift("CREATE TABLE axum_dsl_migrations (version TEXT PRIMARY KEY, sha256 TEXT NOT NULL, applied_at TEXT NOT NULL);")
    sql << "INSERT INTO notes (body, created_at, tag) VALUES ('hello console', '2026-11-13', NULL);"
    _out, err, status = Open3.capture3("sqlite3", db, stdin_data: sql.join("\n"))
    assert status.success?, err
  end

  def console(db, out, stdin)
    Open3.capture3(RbConfig.ruby, EXE, "console", NOTES, "-o", out, "--db", db, stdin_data: stdin)
  end

  def test_end_to_end_reads_run_writes_and_pending_migrations_are_refused
    skip "no cargo" unless tool?("cargo", "--version")
    skip "no sqlite3 command" unless tool?("sqlite3", "--version")
    Dir.mktmpdir("console_e2e") do |dir|
      out = File.join(dir, "crate")
      pending = File.join(dir, "pending.db")
      File.write(pending, "")
      _o, err, status = console(pending, out, ".quit\n")
      assert_equal 2, status.exitstatus
      assert_includes err, "has migrations that are not applied"
      assert_includes err, "001_"

      db = File.join(dir, "notes.db")
      seed(db)
      stdout, err, status = console(db, out, "recent_notes(limit: 5)\nfind_note(id: 99)\nadd_note(body: \"x\")\n.quit\n")
      assert status.success?, err
      assert_includes stdout, AxumDsl::Console::BANNER
      assert_includes stdout, "hello console"
      assert_includes stdout, "1 row,"
      assert_includes stdout, "0 rows,"
      assert_includes stdout, "error: statement `add_note` writes, and the console is read-only"
      assert_equal "1", Open3.capture2("sqlite3", db, "SELECT count(*) FROM notes")[0].strip # the write did not happen
    end
  end
end
