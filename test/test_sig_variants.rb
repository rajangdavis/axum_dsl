# frozen_string_literal: true

# A DSL name may carry one signature per context (schema.rb, AxumDsl.sig_variants): a SIG entry is one hash, or an
# Array of hashes whose `in:` sets do not overlap. The helpers take the table as an argument, so these cases run on
# hand-built tables and leave the real SIG alone.
#
#   ruby -Ilib test/test_sig_variants.rb
require "minitest/autorun"
require "tmpdir"
require "axum_dsl"

class TestSigVariants < Minitest::Test
  ROUTE = { in: :top, names: [], pos: [], kw: { path: [:str, true] }, block: :body }.freeze
  FILTER = { in: :model, names: [:name], pos: [:snake], kw: {}, block: :body }.freeze
  PLAIN = { in: %i[top model], names: [:name], pos: [:camel], kw: {}, block: :decls }.freeze
  TABLE = { scope: [ROUTE, FILTER], record: PLAIN }.freeze

  def test_a_context_picks_its_own_signature
    assert_same ROUTE, AxumDsl.sig(:scope, :top, TABLE)
    assert_same FILTER, AxumDsl.sig(:scope, :model, TABLE)
  end

  def test_a_context_the_name_is_not_allowed_in_has_no_signature
    assert_nil AxumDsl.sig(:scope, :cable, TABLE)
    assert_nil AxumDsl.sig(:nothing, :top, TABLE)
  end

  def test_variants_lists_every_signature_and_wraps_a_single_hash
    assert_equal [ROUTE, FILTER], AxumDsl.sig_variants(:scope, TABLE)
    assert_equal [PLAIN], AxumDsl.sig_variants(:record, TABLE)
    assert_equal [], AxumDsl.sig_variants(:nothing, TABLE)
  end

  def test_names_in_a_context_come_from_every_variant
    assert_equal %i[scope record], AxumDsl.sig_names(:model, TABLE)
    assert_equal %i[scope record], AxumDsl.sig_names(:top, TABLE)
    assert_equal [], AxumDsl.sig_names(:cable, TABLE)
  end

  def test_each_sig_yields_one_pair_per_signature
    assert_equal [[:scope, ROUTE], [:scope, FILTER], [:record, PLAIN]], AxumDsl.each_sig(TABLE).to_a
  end

  def test_overlapping_variants_are_refused
    clash = { scope: [ROUTE, FILTER.merge(in: %i[model top])] }
    error = assert_raises(ArgumentError) { AxumDsl.check_sigs!(clash) }
    assert_includes error.message, "`scope` has two signatures for :top"
  end

  def test_disjoint_variants_pass_the_check
    AxumDsl.check_sigs!(TABLE)
  end

  def test_every_name_of_the_real_table_has_one_signature_that_is_the_entry_itself
    AxumDsl::SIG.each do |name, entry|
      next if entry.is_a?(Array)

      assert_equal [entry], AxumDsl.sig_variants(name)
      Array(entry[:in]).each { |ctx| assert_same entry, AxumDsl.sig(name, ctx), "#{name} in #{ctx}" }
    end
  end

  def test_the_real_table_lists_the_calls_of_a_context_in_table_order
    # An entry is one signature or a list of them (a name with a signature per context), so the expectation looks at each.
    expected = AxumDsl::SIG.select { |_, s| [s].flatten.any? { |v| Array(v[:in]).include?(:cable) } }.keys
    assert_equal expected, AxumDsl.sig_names(:cable)
  end

  def test_a_call_in_the_wrong_context_is_refused_naming_what_is_valid_there
    Dir.mktmpdir("sig") do |dir|
      file = File.join(dir, "x.axum.rb")
      File.write(file, %(server "x", version: "0.1.0"\nrecord :Tag do\n  server "y", version: "0.1.0"\nend\n))
      error = assert_raises(AxumDsl::CompileError) { AxumDsl.read(file) }
      assert_includes error.message, "`server` is not allowed in `record` (valid there: field"
      assert_includes error.message, "it belongs in the top level"
    end
  end
end
