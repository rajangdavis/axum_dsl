# frozen_string_literal: true

# `not_found skip: [:name]`: a request no route matched does not run the named `before` filter, as Rails routes a
# request before any controller filter runs (an unknown path is a 404 even when signed out).
#
#   ruby -Ilib test/test_not_found_skip.rb
require "minitest/autorun"
require "tmpdir"
require "axum_dsl"

class TestNotFoundSkip < Minitest::Test
  def files(src)
    Dir.mktmpdir("nf") do |dir|
      file = File.join(dir, "nf.axum.rb")
      File.write(file, src)
      AxumDsl::Emit.files(AxumDsl.read(file), file)
    end
  end

  APP = <<~RB
    server "nf", version: "0.1.0"

    before :authenticate do
      return redirect("/login") if request_path != "/login"
      "continue"
    end

    get "/login", skip: [:authenticate] do
      text("sign in")
    end

    not_found skip: [:authenticate] do
      status 404
      text("no such page")
    end
  RB

  def test_an_unmatched_request_steps_the_filter_aside
    out = files(APP)
    assert_includes out["src/main.rs"], "if request.extensions().get::<::axum::extract::MatchedPath>().is_none() {"
    assert_includes out["Cargo.toml"], '"matched-path"'
  end

  def test_without_skip_the_filter_runs_for_everything
    out = files(APP.sub("not_found skip: [:authenticate] do", "not_found do"))
    refute_includes out["src/main.rs"], "MatchedPath"
    refute_includes out["Cargo.toml"], "matched-path"
  end

  def test_an_unknown_filter_is_refused
    err = assert_raises(AxumDsl::CompileError) { files(APP.sub("not_found skip: [:authenticate]", "not_found skip: [:auth]")) }
    assert_includes err.message, "not_found skips `:auth`, but no `before :auth` filter is declared"
  end
end
