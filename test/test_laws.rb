# frozen_string_literal: true

# Laws in axum_dsl: `law :name, forall: :Params do |a, b| <bool> end` compiles to a seeded proptest test
# (lib/laws, shared with clap_dsl). The emitted tests are checked here; AXUM_CARGO=1 also runs them, plus a
# planted bug the laws must catch.
#
#   ruby -Ilib test/test_laws.rb
require "minitest/autorun"
require "tmpdir"
require "open3"
require "axum_dsl"

class TestLaws < Minitest::Test
  EXAMPLE = File.expand_path("../examples/laws.axum.rb", __dir__)

  def emit(src)
    Dir.mktmpdir("laws") do |dir|
      file = File.join(dir, "app.axum.rb")
      File.write(file, src)
      AxumDsl::Emit.files(AxumDsl.read(file), file)
    end
  end

  def head(extra = "")
    <<~RB
      server "lawy", version: "0.1.0"
      params :Pair do
        field :a, :i64, min: -10, max: 10
        field :b, :i64, exclusive_min: 0, exclusive_max: 5
      end
      helper :add, args: [:i64, :i64], returns: :i64 do |a, b|
        a + b
      end
      #{extra}
      get "/sum", params: :Pair do
        text(add(params[:a], params[:b]).to_s)
      end
    RB
  end

  def refused(src)
    assert_raises(AxumDsl::CompileError) { emit(src) }.message
  end

  def test_a_law_is_a_seeded_proptest_over_its_fields
    files = emit(head + "law :commutes, forall: :Pair do |a, b|\n  add(a, b) == add(b, a)\nend\n")
    main = files["src/main.rs"]
    assert_includes main, "#[cfg(test)]\nmod laws {"
    assert_includes main, "fn law_commutes(a: i64, b: i64) -> Result<bool, String> {"
    assert_includes main, "((-10i64..=10i64), (1i64..=4i64))", "exclusive bounds become the inclusive ones beside them"
    assert_includes main, 'std::env::var("AXUM_DSL_SEED")'
    assert_includes main, "law commutes (app.axum.rb:"
    assert_includes files["Cargo.toml"], "[dev-dependencies]\nproptest = \"1\""
  end

  def test_no_laws_no_test_module_or_proptest
    files = emit(head)
    refute_includes files["src/main.rs"], "mod laws"
    refute_includes files["Cargo.toml"], "proptest"
  end

  def test_an_example_law_runs_once
    main = emit(head + "law :two_and_three do\n  add(2, 3) == 5\nend\n")["src/main.rs"]
    assert_includes main, "fn law_two_and_three() -> Result<bool, String> {"
    assert_includes main, "match law_two_and_three() {"
  end

  # What only laws call is compiled into release too, but nothing there calls it: -Dwarnings must still pass.
  def test_law_only_helpers_and_runtime_are_allowed_dead_in_release
    extra = <<~RB
      helper :inner, args: [:i64], returns: :i64 do |x|
        x
      end
      helper :outer, args: [:i64], returns: :i64 do |x|
        inner(x)
      end
    RB
    main = emit(head(extra) + "law :doubles, forall: :Pair do |a|\n  outer(a) * 2 == a + a\nend\n")["src/main.rs"]
    attr = "#[cfg_attr(not(test), allow(dead_code))]"
    assert_includes main, "#{attr}\nfn helper_outer("
    assert_includes main, "#{attr}\nfn helper_inner(", "a helper only a law-only helper calls is law-only too"
    refute_includes main, "#{attr}\nfn helper_add(", "a route calls add"
    assert_includes main, "#{attr}\nfn ck_mul_i64(", "the law's own multiplication"
  end

  def test_a_params_group_only_a_law_uses_is_used
    src = head + "params :Word do\n  field :w, :string, max_length: 8\nend\n" \
                 "law :w_short, forall: :Word do |w|\n  w.length <= 8\nend\n"
    main = emit(src)["src/main.rs"]
    assert_includes main, "fn law_w_short(w: String)"
    refute_match(/struct Word\b/, main, "a law-only group writes no struct")
  end

  def test_a_route_law_sends_requests_in_process
    src = head + "law :sums, forall: :Pair do |a, b|\n  r = respond(:get, \"/sum?a=\#{a}&b=\#{b}\", headers: { \"Accept\" => \"text/plain\" })\n" \
                 "  r.status == 200 && r.body == (a + b).to_s\nend\n"
    files = emit(src)
    main = files["src/main.rs"]
    assert_includes main, 'axum_dsl_law_respond("GET", &format!("/sum?a={}&b={}", a, b), String::new(), vec![("Accept".to_string(), "text/plain".to_string())])?'
    assert_includes main, "async fn axum_dsl_start() {"
    assert_includes main, "fn axum_dsl_app() -> axum::Router {"
    assert_includes main, "    let router = axum_dsl_app();"
    assert_includes main, "struct AxumDslLawResponse {"
    assert_includes files["Cargo.toml"], 'tower = { version = "0.5", features = ["util"] }'
    plain = emit(head + "law :x do\n  add(1, 1) == 2\nend\n")
    refute_includes plain["src/main.rs"], "fn axum_dsl_app()", "main stays one function without route laws"
    refute_includes plain["Cargo.toml"], "tower ="
  end

  def test_respond_is_only_for_laws
    route = head.sub('text(add(params[:a], params[:b]).to_s)', 'r = respond(:get, "/sum")' + "\n  text(r.body)")
    assert_includes refused(route), "respond(...) is for a law's body"
    assert_includes refused(head + "law :x do\n  respond(:fetch, \"/\").status == 200\nend\n"), "respond takes a method"
    assert_includes refused(head + "law :x do\n  respond(:get, \"/\", query: \"a\").status == 200\nend\n"), "not `query:`"
  end

  QUERY_HEAD = <<~RB
    server "qlaws", version: "0.1.0"
    database :sqlite, path: "q.db"
    record :Row do
      field :id, :i64
      field :name, :string
    end
    query :rows_old, args: { limit: :i64 }, returns: list(:Row), sql: "SELECT id, name FROM t ORDER BY id LIMIT :limit"
    query :rows_new, args: { limit: :i64 }, returns: list(:Row), sql: "SELECT id, name FROM t ORDER BY id LIMIT :limit"
    query :row_one, args: { id: :i64 }, returns: :Row?, sql: "SELECT id, name FROM t WHERE id = :id"
    query :row_count, args: {}, returns: :i64, sql: "SELECT count(*) FROM t"
    execute :wipe, args: {}, sql: "DELETE FROM t"
    params :Page do
      field :limit, :i64, min: 0, max: 5
    end
    get "/rows" do
      json(rows_new(limit: 3))
    end
    get "/one" do
      json(row_one(id: 1))
    end
    get "/count" do
      row_count().to_s
    end
    post "/wipe" do
      wipe()
      "ok"
    end
  RB

  def test_a_law_compares_two_queries_on_the_laws_runtime
    src = QUERY_HEAD + "law :same, forall: :Page, cases: 8 do |limit|\n  rows_old(limit: limit) == rows_new(limit: limit)\nend\n" \
                       "law :one_is_one do\n  row_one(id: 1) == row_one(id: 1) && row_count() == row_count()\nend\n"
    files = emit(src)
    main = files["src/main.rs"]
    assert_includes main, "{ axum_dsl_law_started(); law_runtime().block_on(query_rows_old(limit))? } == " \
                          "{ axum_dsl_law_started(); law_runtime().block_on(query_rows_new(limit))? }"
    assert_includes main, "{ axum_dsl_law_started(); law_runtime().block_on(query_row_one(1))? }"
    assert_includes main, "#[derive(Clone, PartialEq, serde::Serialize)]\nstruct Row {", "records compare field by field"
    assert_includes main, "async fn axum_dsl_start() {", "the laws run after the service's own startup"
    attr = "#[cfg_attr(not(test), allow(dead_code))]"
    assert_includes main, "#{attr}\nasync fn query_rows_old(", "only the law calls rows_old"
    refute_includes main, "#{attr}\nasync fn query_rows_new(", "a route calls rows_new"
    # Without the laws nothing calls rows_old or quantifies over Page, and an unused declaration is refused.
    plain = emit(QUERY_HEAD.sub(/^query :rows_old.*\n/, "").sub(/^params :Page do\n.*?^end\n/m, ""))["src/main.rs"]
    assert_includes plain, "#[derive(Clone, serde::Serialize)]\nstruct Row {", "no law compares: no PartialEq"
  end

  def test_a_law_reads_fields_of_a_query_result
    src = QUERY_HEAD + "law :names, forall: :Page, cases: 4 do |limit|\n" \
                       "  (row_one(id: limit)&.name || \"\") == \"\" || rows_old(limit: limit).map { |r| r.name }.join(\",\") == rows_new(limit: limit).map { |r| r.name }.join(\",\")\nend\n"
    main = emit(src)["src/main.rs"]
    assert_includes main, "__o.name.clone()", "&. reads a field of a :Row? result"
    assert_includes main, ".name.clone()", "map reads a field of a list(:Row) result"
  end

  def test_a_query_comparison_ends_an_all_block_in_a_law
    head = QUERY_HEAD.sub(/^query :rows_old.*\n/, "").sub(/^params :Page do\n.*?^end\n/m, "")
    src = head + "law :same_rows do\n  [1, 2].all? do |n|\n    row_one(id: n) == row_one(id: n)\n  end\nend\n"
    main = emit(src)["src/main.rs"]
    call = "{ axum_dsl_law_started(); law_runtime().block_on(query_row_one(n))? }"
    assert_includes main, "let n = *__e; (#{call} == #{call}) }", "a block that starts the tail is parenthesised"
  end

  def test_a_law_may_call_queries_but_not_executes
    assert_includes refused(QUERY_HEAD + "law :x do\n  wipe() == 0\nend\n"), "writes to the database; a law may call `query` statements only"
    helper = "helper :n, args: [], returns: :i64 do\n  row_count()\nend\n"
    assert_includes refused(QUERY_HEAD + helper), "runs in a route, a filter or a `current` body, not in a helper or a binding"
  end

  def test_refusals
    assert_includes refused(head + "law :x, forall: :Pairs do |a|\n  a == a\nend\n"), "no params group has that name"
    assert_includes refused(head + "law :x, forall: :Pair do |c|\n  c == c\nend\n"), "`c` is not a field of Pair (fields: a, b)"
    assert_includes refused(head + "law :x do |a|\n  a == a\nend\n"), "an example law takes no parameters"
    assert_includes refused(head + "law :x, cases: 5 do\n  true\nend\n"), "`cases:` needs `forall:`"
    assert_includes refused(head + "law :x do\n  true\nend\nlaw :x do\n  true\nend\n"), "duplicate law `x`"
    assert_includes refused(head + "law :x, forall: :Pair do |a|\n  a + 1\nend\n"), "returns bool but its body ends in i64"
    m = "params :M do\n  field :n, :i64, multiple_of: 3\nend\nlaw :x, forall: :M do |n|\n  n == n\nend\n"
    assert_includes refused(head + m), "has `multiple_of:`, which a law cannot generate exactly yet"
    f = "params :F do\n  field :x, :f64, exclusive_min: 0.0\nend\nlaw :y, forall: :F do |x|\n  x > 0.0\nend\n"
    assert_includes refused(head + f), "an exclusive bound on an :f64"
  end

  # The example's laws hold, and a planted off-by-one in `add` is caught with its minimal input.
  def test_cargo_runs_the_laws_and_catches_a_planted_bug
    skip "set AXUM_CARGO=1 to build and run the laws" unless ENV["AXUM_CARGO"]

    Dir.mktmpdir("laws-cargo") do |dir|
      ok, out = cargo_test(File.read(EXAMPLE), dir, "good")
      assert ok, out
      assert_match(/test result: ok\. \d+ passed/, out)
      ok, out = cargo_test(File.read(EXAMPLE).sub(/^  a \+ b$/, "  a == 7 ? a + b + 1 : a + b"), dir, "planted")
      refute ok, "the planted bug passed every law"
      assert_includes out, "law add_commutes"
      assert_includes out, "minimal failing input"
    end
  end

  # The query laws hold on a seeded database (a second migration in a copy of the example's folder), and a relation
  # port that orders the other way round is caught.
  def test_cargo_runs_the_query_laws_and_catches_a_wrong_port
    skip "set AXUM_CARGO=1 to build and run the laws" unless ENV["AXUM_CARGO"]

    Dir.mktmpdir("qlaws-cargo") do |dir|
      FileUtils.cp_r(File.expand_path("../examples/notes", __dir__), dir)
      rows = (1..9).map { |i| "(#{i}, 'note #{i}', '2026-01-0#{i}', #{i.odd? ? "'t'" : 'NULL'})" }.join(", ")
      File.write(File.join(dir, "notes/db/migrate/002_seed.sql"), "INSERT INTO notes (id, body, created_at, tag) VALUES #{rows};\n")
      src = File.read(File.expand_path("../examples/query_laws.axum.rb", __dir__))
      ok, out = cargo_test(src, dir, "good", "DATABASE_PATH" => File.join(dir, "good.sqlite3"))
      assert ok, out
      assert_match(/test result: ok\. 2 passed/, out)
      planted = src.sub("order(id: :desc)", "order(id: :asc)")
      ok, out = cargo_test(planted, dir, "planted", "DATABASE_PATH" => File.join(dir, "planted.sqlite3"))
      refute ok, "the wrong port passed every law"
      assert_includes out, "law recent_notes_match_their_sql"
    end
  end

  def cargo_test(src, dir, name, extra_env = {})
    file = File.join(dir, "#{name}.axum.rb")
    File.write(file, src)
    out = File.join(dir, name)
    AxumDsl::Emit.files(AxumDsl.read(file), file).each do |path, text|
      FileUtils.mkdir_p(File.dirname(File.join(out, path)))
      File.write(File.join(out, path), text)
    end
    AxumDsl::Lockfile.pin(out, AxumDsl::Emit::VETTED_LOCK)
    env = { "RUSTFLAGS" => "-Dwarnings", "CARGO_TARGET_DIR" => File.join(Dir.tmpdir, "axum_dsl_laws_target") }.merge(extra_env)
    build, st0 = Open3.capture2e(env, "cargo", "build", "--quiet", "--locked", chdir: out) # release-shaped: law-only code must not warn
    return [false, build] unless st0.success?

    o, st = Open3.capture2e(env, "cargo", "test", "--quiet", "--locked", chdir: out)
    [st.success?, o]
  end
end
