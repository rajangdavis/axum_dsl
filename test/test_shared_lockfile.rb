# frozen_string_literal: true

# lib/axum_dsl/lockfile.rb is a copy of clap_dsl's (same code, own module name), until the kernel extraction moves
# it into one gem. The copies must stay identical apart from the module name, so a fix in one is not silently
# missing from the other. Needs a clap_dsl checkout beside this one (or CLAP_DSL_DIR); skipped otherwise.
require "minitest/autorun"

class TestSharedLockfile < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  CLAP = ENV["CLAP_DSL_DIR"] || File.expand_path("../clap_dsl", ROOT)

  def test_lockfile_matches_clap_dsl
    theirs = File.join(CLAP, "lib/clap_dsl/lockfile.rb")
    skip "no clap_dsl checkout at #{CLAP}" unless File.file?(theirs)

    want = File.read(theirs).gsub("ClapDsl", "AxumDsl").gsub("clap_dsl", "axum_dsl")
    assert File.read(File.join(ROOT, "lib/axum_dsl/lockfile.rb")) == want, "lib/axum_dsl/lockfile.rb has drifted from clap_dsl; port the change to both"
  end
end
