# frozen_string_literal: true

# `axum_dsl emit-diff`: the generated crate before and after a change, compared in memory. Identical trees, an
# overlay that changes one route, a line that differs only in a DSL position, `--against` a crate emitted
# earlier, a compile error on the "after" side, usage errors, and the splitter leaving string literals whole.
#
#   ruby -Ilib test/test_emit_diff.rb
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "open3"
require "stringio"
require "rbconfig"
require "axum_dsl"

class TestEmitDiff < Minitest::Test
  EXE = File.expand_path("../exe/axum_dsl", __dir__)

  ROOT = <<~RB
    server "diffapp", version: "0.1.0"
    set :port, 8080
    use_dsl "controllers/pages.axum.rb"
  RB

  PAGES = <<~RB
    controller do
      get "/hello" do
        text("hello")
      end

      get "/bye" do
        text("bye")
      end
    end
  RB

  def project
    Dir.mktmpdir("emit_diff") do |dir|
      FileUtils.mkdir_p(File.join(dir, "controllers"))
      File.write(File.join(dir, "app.axum.rb"), ROOT)
      File.write(File.join(dir, "controllers", "pages.axum.rb"), PAGES)
      yield dir, File.join(dir, "app.axum.rb")
    end
  end

  def emit_diff(*args, stdin: "")
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, EXE, "emit-diff", *args, stdin_data: stdin)
    [stdout, stderr, status.exitstatus]
  end

  def overlay(text) = JSON.generate("controllers/pages.axum.rb" => text)

  def test_identical_trees_say_so_and_exit_0
    project do |_dir, root|
      out, err, code = emit_diff(root, "--overlay", "-", stdin: "{}")
      assert_equal 0, code, err
      assert_match(/identical/, out)
    end
  end

  def test_an_overlay_that_changes_one_route_names_it_and_shows_the_piece
    project do |_dir, root|
      out, err, code = emit_diff(root, "--overlay", "-", stdin: overlay(PAGES.sub('text("hello")', 'text("hello there")')))
      assert_equal 1, code, err
      summary = out.lines.grep(/\Achanged:/)
      assert_equal 1, summary.size, out
      assert_match(/\Achanged: route `get \/hello` \(\S*controllers\/pages\.axum\.rb:2\)/, summary.first)
      assert_match(/^-.*"hello"/, out)
      assert_match(/^\+.*"hello there"/, out)
      refute_match(/bye/, out.lines.grep(/\A[-+]/).join, "the other route is not in the diff")
      assert_match(/^@@ .* @@ route `get \/hello`/, out)
    end
  end

  def test_summary_prints_no_diff
    project do |_dir, root|
      out, err, code = emit_diff(root, "--overlay", "-", "--summary", stdin: overlay(PAGES.sub('text("hello")', 'text("hi")')))
      assert_equal 1, code, err
      refute_match(/^@@|^---/, out)
      assert_match(/changed: route/, out)
    end
  end

  def test_a_route_added_in_the_overlay_is_reported_as_added
    project do |_dir, root|
      more = PAGES.sub(/end\n\z/, "\n  get \"/new\" do\n    text(\"new\")\n  end\nend\n")
      refute_equal PAGES, more
      out, err, code = emit_diff(root, "--overlay", "-", "--summary", stdin: overlay(more))
      assert_equal 1, code, err
      assert_match(/^added: route `get \/new`/, out)
    end
  end

  def test_a_line_that_differs_only_in_a_dsl_line_number_is_ignored_and_counted
    before = { "src/main.rs" => "fn a() {}\n(\"bot\", \"models/bot.axum.rb:94\", 1);\n// def create_bot, models/bot.axum.rb:31\n" }
    after = { "src/main.rs" => "fn a() {}\n(\"bot\", \"models/bot.axum.rb:95\", 1);\n// def create_bot, models/bot.axum.rb:32\n" }
    result = AxumDsl::EmitDiff.compare(before, after)
    assert_empty result[:summary]
    assert_equal 2, result[:masked]
    assert_equal 1, AxumDsl::EmitDiff.compare(before, after, mask: false)[:summary].size.clamp(0, 1), "unmasked, the lines differ"
    out = StringIO.new
    assert_equal 0, AxumDsl::EmitDiff.report(result, summary: false, out: out)
    assert_match(/identical \(2 lines differ only in a DSL line number\)/, out.string)
  end

  def test_a_blank_line_above_the_routes_changes_nothing
    project do |_dir, root|
      out, err, code = emit_diff(root, "--overlay", "-", stdin: overlay("\n" + PAGES))
      assert_equal 0, code, err
      assert_match(/identical/, out)
    end
  end

  def test_against_a_crate_emitted_from_the_same_source_is_identical
    project do |dir, root|
      crate = File.join(dir, "kept")
      _out, err, status = Open3.capture3(RbConfig.ruby, EXE, root, "-o", crate)
      assert status.success?, err
      out, err, code = emit_diff(root, "--against", crate)
      assert_equal 0, code, err
      assert_match(/identical/, out)

      File.write(File.join(dir, "controllers", "pages.axum.rb"), PAGES.sub('text("bye")', 'text("see you")'))
      out, err, code = emit_diff(root, "--against", crate)
      assert_equal 1, code, err
      assert_match(/changed: route `get \/bye`/, out)
    end
  end

  def test_against_a_missing_directory_names_it_and_the_command_that_makes_it
    project do |dir, root|
      _out, err, code = emit_diff(root, "--against", File.join(dir, "nope"))
      assert_equal 2, code
      assert_includes err, File.join(dir, "nope")
      assert_includes err, "-o"
    end
  end

  def test_a_compile_error_in_the_overlay_names_the_after_side
    project do |_dir, root|
      _out, err, code = emit_diff(root, "--overlay", "-", stdin: overlay("controller do\n  get \"/x\" do\n    nope_undefined(\n  end\nend\n"))
      assert_equal 2, code
      assert_match(/"after" side does not compile/, err)
      assert_includes err, "pages.axum.rb"
    end
  end

  def test_usage_errors_exit_2
    project do |_dir, root|
      assert_equal 2, emit_diff(root)[2], "neither option"
      assert_equal 2, emit_diff(root, "--against", "x", "--overlay", "-", stdin: "{}")[2], "both options"
      assert_equal 2, emit_diff("--overlay", "-", stdin: "{}")[2], "no file"
      assert_equal 2, emit_diff(root, "extra", "--overlay", "-", stdin: "{}")[2], "an extra argument"
      assert_equal 2, emit_diff(root, "--overlay", "-", stdin: "[1]")[2], "an overlay that is not an object of texts"
    end
  end

  def test_the_splitter_never_splits_inside_a_string_literal
    inside = "a; b { c } d; \\\" e; { f }" * 8
    line = %(    println!("#{inside}");)
    assert_operator line.length, :>, AxumDsl::EmitDiff::LONG
    assert_equal [line], AxumDsl::EmitDiff.split_line(line)
  end

  def test_the_splitter_cuts_a_long_line_at_statement_boundaries
    line = "    " + (1..12).map { |i| "let value_number_#{i} = compute(#{i});" }.join(" ") + " if ok { run(); } else { stop(); }"
    pieces = AxumDsl::EmitDiff.split_line(line)
    assert_operator pieces.size, :>, 12
    assert(pieces.all? { |p| p.length <= AxumDsl::EmitDiff::LONG })
    assert_equal line.gsub(/\s+/, ""), pieces.join.gsub(/\s+/, ""), "splitting loses nothing"
    assert_includes pieces, "    if ok {"
    assert_includes pieces, "        run();"
  end

  def test_a_short_line_is_left_alone
    assert_equal ["let x = 1; let y = 2;"], AxumDsl::EmitDiff.split_line("let x = 1; let y = 2;")
  end

  def test_a_line_that_differs_only_in_a_statement_index_is_ignored_and_counted
    call = ->(i) { %(    db_run(#{i}, "last_page", move |__c| db_last_page(__c, room_id))\n) }
    before = { "src/main.rs" => "fn a() {}\n#{call.call(3)}#{call.call(4)}" }
    after = { "src/main.rs" => "fn a() {}\n#{call.call(4)}#{call.call(5)}" }
    result = AxumDsl::EmitDiff.compare(before, after)
    assert_empty result[:summary]
    assert_equal 2, result[:masked]
    refute_empty AxumDsl::EmitDiff.compare(before, after, mask: false)[:summary], "unmasked, the indexes differ"
    changed = { "src/main.rs" => "fn a() {}\n#{call.call(4).sub('room_id', 'room_id, 40')}#{call.call(5)}" }
    refute_empty AxumDsl::EmitDiff.compare(before, changed)[:diff], "a change beside the index is still reported"
  end

  def test_a_statement_that_moved_between_model_files_is_reported_once
    map = lambda do |file, line|
      { AxumDsl::CargoBuild::MAP => JSON.generate("ranges" => [{ "from" => 2, "to" => 2, "what" => "execute `x`", "dsl_file" => file, "dsl_line" => line }]) }
    end
    before = { "src/main.rs" => "fn a() {}\nlet x = 1;\n" }.merge(map.call("models/a.axum.rb", 5))
    after = { "src/main.rs" => "fn a() {}\nlet x = 2;\n" }.merge(map.call("models/b.axum.rb", 9))
    result = AxumDsl::EmitDiff.compare(before, after)
    assert_equal ["moved: execute `x` (models/a.axum.rb:5 -> models/b.axum.rb:9)"], result[:summary]
    assert_match(/^-let x = 1;/, result[:diff].join("\n"))
    assert_match(/^\+let x = 2;/, result[:diff].join("\n"))
  end

  def test_a_statement_added_in_one_file_and_removed_in_another_under_different_names_is_not_a_move
    map = lambda do |what, file|
      { AxumDsl::CargoBuild::MAP => JSON.generate("ranges" => [{ "from" => 2, "to" => 2, "what" => what, "dsl_file" => file, "dsl_line" => 1 }]) }
    end
    before = { "src/main.rs" => "fn a() {}\nlet x = 1;\n" }.merge(map.call("execute `x`", "models/a.axum.rb"))
    after = { "src/main.rs" => "fn a() {}\nlet y = 1;\n" }.merge(map.call("execute `y`", "models/b.axum.rb"))
    assert_equal ["added: execute `y` (models/b.axum.rb:1)", "removed: execute `x` (models/a.axum.rb:1)"], AxumDsl::EmitDiff.compare(before, after)[:summary].sort
  end
end
