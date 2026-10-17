# frozen_string_literal: true

# L7: every file in test/refusals/ must be REFUSED by the compiler, with the message named in
# its first line (`# expect: ...`). Each refusal is a rule of the DSL; this keeps the messages
# (and the rules) from silently disappearing.
#
#   ruby -Ilib test/test_refusals.rb
require "minitest/autorun"
require "open3"
require "rbconfig"

class TestRefusals < Minitest::Test
  EXE = File.expand_path("../exe/axum_dsl", __dir__)
  REFUSALS = File.expand_path("refusals", __dir__)

  Dir.glob(File.join(REFUSALS, "*.rb")).sort.each do |file|
    expect = File.foreach(file).first[/\A# expect: (.+)\s*\z/, 1] or raise "#{file}: first line must be `# expect: ...`"

    define_method("test_refuses_#{File.basename(file, ".rb")}") do
      _out, err, status = Open3.capture3(RbConfig.ruby, EXE, file, "--check")
      refute status.success?, "#{File.basename(file)} should be refused"
      assert_includes err, expect, "#{File.basename(file)}: wrong message:\n#{err}"
      assert_match(/\A#{Regexp.escape(file)}:\d+:\d+: /, err, "the message should start with FILE:LINE:COL:\n#{err}")
    end
  end

  # A refusal fixture must never become a way to smuggle in a rule that also refuses something the
  # compiler accepts, so every example still has to compile.
  def test_every_example_still_compiles
    Dir.glob(File.expand_path("../examples/*.axum.rb", __dir__)).sort.each do |file|
      _out, err, status = Open3.capture3(RbConfig.ruby, EXE, file, "--check")
      assert status.success?, "#{file} should compile:\n#{err}"
    end
  end

  # bin/probe carries the project list of constructs the compiler must refuse (`[:refuse, "..."]`).
  # Every one of them needs a fixture here, so a refusal added to that list cannot pass with
  # nothing pinning its message.
  PROBE_REFUSALS = {
    "path: list field, refused" => "path_list_field",
    "path: optional segment (?), refused" => "path_optional_segment",
    "path: parenthesised group, refused" => "path_paren_group",
    "path: regex metacharacter, refused" => "path_regex_metachar",
    "pattern: lookahead, refused" => "pattern_lookahead",
    "default: does not match pattern, refused" => "pattern_default_mismatch"
  }.freeze

  def test_every_probe_refusal_has_a_fixture
    labels = File.read(File.expand_path("../bin/probe", __dir__)).scan(/\[:refuse,\s*"([^"]+)"/).flatten
    refute_empty labels, "no [:refuse, ...] rows found in bin/probe"
    labels.each do |label|
      fixture = PROBE_REFUSALS[label]
      refute_nil fixture, "bin/probe refuses #{label.inspect} but no fixture is mapped for it; add one under test/refusals/ and a row here"
      assert File.file?(File.join(REFUSALS, "#{fixture}.rb")), "#{fixture}.rb is mapped to #{label.inspect} but does not exist"
    end
  end
end
