# frozen_string_literal: true

# A generated crate is pinned to the vetted dependency set (lib/axum_dsl/vetted/Cargo.lock, made by bin/vet_lock)
# and builds with --locked; a release build carries its dependency list. These build crates, so they need
# AXUM_CARGO=1 (make test-ruby-rust), apart from the rust_crate one; test_lockfile.rb covers the lock handling without cargo.
#
#   AXUM_CARGO=1 ruby -Ilib test/test_e2e_pin.rb
require "minitest/autorun"
require "tmpdir"
require "open3"
require "rbconfig"
require "axum_dsl"

class TestE2ePin < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  EXE = File.join(ROOT, "exe/axum_dsl")

  def need_cargo
    skip "set AXUM_CARGO=1 to build crates (make test-ruby-rust)" unless ENV["AXUM_CARGO"]
  end

  def axum_dsl(*args) = Open3.capture3(RbConfig.ruby, EXE, *args, chdir: ROOT)

  # Each crate's Cargo.lock is the vetted set trimmed by cargo: only what the crate uses, nothing the set lacks.
  def test_pinned_lock_is_a_trimmed_subset
    need_cargo
    Dir.mktmpdir do |dir|
      _, err, st = axum_dsl("build", "examples/add.axum.rb", "-o", dir, "--emit-only")
      assert st.success?, err
      lock = File.read(File.join(dir, "Cargo.lock"))
      vetted = File.read(AxumDsl::Emit::VETTED_LOCK)
      assert_empty AxumDsl::Lockfile.outside(lock, vetted)
      assert_includes vetted, %(name = "rusqlite")
      refute_includes lock, %(name = "rusqlite"), "add declares no database, so rusqlite is trimmed"
    end
  end

  # A crate with its own rust_crate leaves the vetted set: no pin, and the warning names the crate.
  def test_a_rust_crate_leaves_the_vetted_set
    Dir.mktmpdir do |dir|
      _, err, st = axum_dsl("build", "examples/hatches.axum.rb", "-o", dir, "--emit-only")
      assert st.success?, err
      assert_includes err, "rust_crate heck is outside the vetted dependency set"
      refute File.exist?(File.join(dir, "Cargo.lock")), "an unpinned crate gets no Cargo.lock"
    end
  end

  # A release build embeds its dependency list (cargo auditable's .dep-v0 section), so the deployed binary can be
  # audited on its own; without it `cargo audit bin` would only guess from panic messages.
  def test_release_binary_is_auditable
    need_cargo
    Dir.mktmpdir do |dir|
      _, err, st = axum_dsl("build", "examples/add.axum.rb", "-o", dir, "--release")
      assert st.success?, err
      target = ENV["CARGO_TARGET_DIR"] || File.join(dir, "target")
      bin = File.join(target, "release", "calculator")
      assert_includes File.binread(bin), ".dep-v0", "no embedded dependency list in #{bin}"
      out, err, st = Open3.capture3("cargo", "audit", "bin", bin)
      assert st.success?, out + err
    end
  end
end
