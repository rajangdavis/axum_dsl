# frozen_string_literal: true

# L2 golden: pin the Rust text the emitter produces for each example, so a refactor, a dependency
# bump or a formatting tweak in lib/axum_dsl/emit.rb cannot change it silently. rmcp_dsl/SPEC.md
# section 3 describes this layer as "DSL snippet -> expected Rust text (spec/golden/*.rs)"; it was
# never built there either, so the shape here is chosen for this tree. The goldens live under
# test/golden/ beside the other test data (test/ holds every test and its data; spec/ holds only the
# shim catalogue), one pair of files per example: `<name>.main.rs` and `<name>.Cargo.toml`.
#
# The golden text was HAND-DERIVED by reading lib/axum_dsl/emit.rb and tracing it for each example,
# because the container that wrote it has no Ruby. It is expected to be confirmed -- or corrected --
# by the first run; a mismatch prints the first differing line with context, not just "not equal".
#
#   ruby -Ilib test/test_golden.rb                  # check
#   GOLDEN_UPDATE=1 ruby -Ilib test/test_golden.rb  # rewrite the goldens (human only)
#
# Each example is read at its repo-relative path, because the emitter bakes that path into the
# generated arithmetic for a checked operation (for example "examples/add.axum.rb:11:9"). Reading it
# from the repo root keeps the goldens stable whatever the working tree's absolute path is.
require "minitest/autorun"
require "axum_dsl"

class TestGolden < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  GOLDEN_DIR = File.join(ROOT, "test/golden")

  # example name => { path inside the emitted crate => golden file }
  GOLDEN = {
    "add" => { "src/main.rs" => "add.main.rs", "Cargo.toml" => "add.Cargo.toml" },
    "validate" => { "src/main.rs" => "validate.main.rs", "Cargo.toml" => "validate.Cargo.toml" },
    "assets" => { "src/main.rs" => "assets.main.rs", "Cargo.toml" => "assets.Cargo.toml" },
    "views" => { "src/main.rs" => "views.main.rs", "Cargo.toml" => "views.Cargo.toml" },
    "proxy" => { "src/main.rs" => "proxy.main.rs", "Cargo.toml" => "proxy.Cargo.toml" },
    "case" => { "src/main.rs" => "case.main.rs", "Cargo.toml" => "case.Cargo.toml" },
    "split" => { "src/main.rs" => "split.main.rs", "Cargo.toml" => "split.Cargo.toml" },
    "hatches" => { "src/main.rs" => "hatches.main.rs", "Cargo.toml" => "hatches.Cargo.toml" },
    "tls" => { "src/main.rs" => "tls.main.rs", "Cargo.toml" => "tls.Cargo.toml" },
    "notes" => { "src/main.rs" => "notes.main.rs", "Cargo.toml" => "notes.Cargo.toml" },
    "login" => { "src/main.rs" => "login.main.rs", "Cargo.toml" => "login.Cargo.toml" }
  }.freeze

  def test_the_emitted_crate_matches_its_golden
    update = ENV["GOLDEN_UPDATE"]
    changed = []
    GOLDEN.each do |example, files|
      src = "examples/#{example}.axum.rb"
      emitted = Dir.chdir(ROOT) { AxumDsl::Emit.files(AxumDsl.read(src), src) }
      files.each do |in_crate, golden|
        got = emitted.fetch(in_crate)
        path = File.join(GOLDEN_DIR, golden)
        if update
          File.write(path, got)
          next
        end
        want = File.read(path)
        changed << first_difference(src, in_crate, path, want, got) unless want == got
      end
    end
    if update
      puts "rewrote #{GOLDEN.sum { |_, f| f.size }} golden file(s)"
      return
    end
    assert_empty changed, "the emitter no longer matches test/golden:\n\n#{changed.join("\n\n")}"
  end

  def test_every_example_has_a_golden
    GOLDEN.each do |example, files|
      src = "examples/#{example}.axum.rb"
      assert File.file?(File.join(ROOT, src)), "golden names #{src}, which is not in the tree"
      files.each_value do |golden|
        path = File.join(GOLDEN_DIR, golden)
        assert File.file?(path), "no golden at #{path}; run GOLDEN_UPDATE=1 ruby -Ilib test/test_golden.rb"
      end
    end
  end

  private

  # A focused line diff: the first line that differs with three lines of context either side. A whole
  # file dump would bury the one line that moved.
  def first_difference(src, in_crate, path, want, got)
    w = want.lines
    g = got.lines
    at = (0...[w.size, g.size].max).find { |n| w[n] != g[n] } || 0
    last = [w.size, g.size].max - 1
    rows = ([at - 3, 0].max..[at + 3, last].min).map do |n|
      if w[n] == g[n]
        "  #{n + 1}: #{w[n].to_s.chomp}"
      else
        "> want #{n + 1}: #{w[n].to_s.chomp}\n  got  #{n + 1}: #{g[n].to_s.chomp}"
      end
    end
    [
      "#{in_crate} for #{src} differs from #{path.sub("#{ROOT}/", '')}",
      "first difference at line #{at + 1} (golden #{w.size} lines, emitted #{g.size} lines):",
      *rows,
      "re-pin with: GOLDEN_UPDATE=1 ruby -Ilib test/test_golden.rb"
    ].join("\n")
  end
end
