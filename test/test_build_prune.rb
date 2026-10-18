# frozen_string_literal: true

# A build records the files it emitted in DIR/.axum_dsl-files. The next build into the same DIR removes
# the files it no longer emits: the old name of a fingerprinted `static` asset, an asset whose `static` or
# `serve_file` was deleted. It never removes a file it did not write, and a manifest entry that is
# absolute or climbs out of DIR is ignored.
#
#   ruby -Ilib test/test_build_prune.rb
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"
require "axum_dsl"

class TestBuildPrune < Minitest::Test
  EXE = File.expand_path("../exe/axum_dsl", __dir__)

  # Write `body` as a server and emit its crate into `out`, without cargo.
  def build(project, out, body)
    FileUtils.mkdir_p(project)
    file = File.join(project, "prune.axum.rb")
    File.write(file, "server \"prune\", version: \"0.1.0\"\nset :port, 8080\n#{body}")
    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, EXE, "build", file, "-o", out, "--emit-only")
    assert status.success?, stderr
    out
  end

  def manifest(out) = File.readlines(File.join(out, AxumDsl::Manifest::NAME), chomp: true)

  def test_a_changed_static_digest_prunes_the_old_emitted_name
    Dir.mktmpdir("prune") do |dir|
      project = File.join(dir, "project")
      out = File.join(dir, "out")
      FileUtils.mkdir_p(File.join(project, "public"))
      File.write(File.join(project, "public", "campfire.css"), "body { color: red }\n")

      build(project, out, %(static "/assets", dir: "public"\n))
      assert File.exist?(File.join(out, "public", "campfire.css")), "the first build copies the asset at its declared path"

      build(project, out, %(static "/assets", dir: "public", digest: true\n))
      refute File.exist?(File.join(out, "public", "campfire.css")), "the un-fingerprinted name is no longer emitted"
      digest = Dir.glob(File.join(out, "public", "campfire-*.css"))
      assert_equal 1, digest.size, "the fingerprinted name is emitted"
      assert_includes manifest(out), "public/#{File.basename(digest.first)}"
    end
  end

  def test_a_removed_static_is_pruned_and_a_user_file_survives
    Dir.mktmpdir("prune") do |dir|
      project = File.join(dir, "project")
      out = File.join(dir, "out")
      FileUtils.mkdir_p(File.join(project, "public"))
      File.write(File.join(project, "public", "a.txt"), "hello\n")
      build(project, out, %(static "/files", dir: "public"\n))
      assert File.exist?(File.join(out, "public", "a.txt"))

      user = File.join(out, "notes.txt")
      File.write(user, "mine\n")
      build(project, out, %(get "/" do\n  text("ok")\nend\n))
      refute File.exist?(File.join(out, "public", "a.txt")), "the removed mount's copy is pruned"
      assert File.exist?(user), "a file the build did not write is left alone"
      assert File.exist?(File.join(out, AxumDsl::Manifest::NAME)), "the new manifest is written"
    end
  end

  def test_a_first_build_into_a_fresh_directory_removes_nothing
    Dir.mktmpdir("prune") do |dir|
      out = File.join(dir, "out")
      FileUtils.mkdir_p(out)
      keep = File.join(out, "keep.txt")
      File.write(keep, "keep\n")
      build(File.join(dir, "project"), out, %(get "/" do\n  text("ok")\nend\n))
      assert File.exist?(keep), "no manifest means nothing is pruned"
    end
  end

  def test_the_manifest_is_the_emitted_paths_sorted
    Dir.mktmpdir("prune") do |dir|
      out = File.join(dir, "out")
      build(File.join(dir, "project"), out, %(get "/" do\n  text("ok")\nend\n))
      lines = manifest(out)
      assert_equal lines.sort, lines
      assert_equal lines.uniq, lines
      assert_includes lines, "Cargo.toml"
      assert_includes lines, "src/main.rs"
      assert_includes lines, AxumDsl::CargoBuild::MAP
      refute_includes lines, AxumDsl::Manifest::NAME
    end
  end

  def test_a_climbing_or_absolute_manifest_entry_deletes_nothing_outside
    Dir.mktmpdir("prune") do |dir|
      out = File.join(dir, "out")
      FileUtils.mkdir_p(out)
      outside = File.join(dir, "outside.txt")
      File.write(outside, "keep\n")
      absolute = File.join(dir, "absolute.txt")
      File.write(absolute, "keep\n")
      File.write(File.join(out, AxumDsl::Manifest::NAME),
                 ["../outside.txt", absolute, "src/main.rs"].join("\n") + "\n")

      build(File.join(dir, "project"), out, %(get "/" do\n  text("ok")\nend\n))
      assert File.exist?(outside), "a .. entry is ignored"
      assert File.exist?(absolute), "an absolute entry is ignored"
      refute_includes manifest(out), "../outside.txt"
      refute_includes manifest(out), absolute
    end
  end
end
