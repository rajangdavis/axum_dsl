# frozen_string_literal: true

# L6: the emitter against the shim catalogue. spec/shims/string.yml is the authority for what each
# string method does -- its Rust template plus literal examples, checked against Ruby by
# `make test-ruby` and against the Rust template by `make test-diff`. But lib/axum_dsl/body.rb
# restates every one of those templates by hand (STRIP_FN, SPLIT_WS, the inline strings for length,
# reverse, to_i, tr, ...), and nothing compared the two: the suites could be green while the emitter
# emitted something the catalogue forbids. This file compares them, entry by entry, by DRIVING the
# emitter -- AxumDsl::Emit.files on a one-route snippet -- and looking for the catalogue template's
# distinguishing text in the Rust it produces. rmcp_dsl/SPEC.md calls this layer L6 ("shim catalog
# names == transpiler table names == lib/rust/ methods"); like L2 it was never automated there.
#
# It also refuses two silences:
#   * a catalogue entry nothing checks (a new entry must appear in DRIVEN or in UNCOVERED), and
#   * a catalogue method name that is neither in Body::ALLOWED_METHODS nor named in OUT_OF_SCOPE.
#
# lib/axum_dsl/body.rb:19 says test/test_skill.rb holds ALLOWED_METHODS and the catalogue equal; that
# file was never ported to this tree, so this test (with test_body_surface.rb, for the rbi side)
# closes that claim:
#
#   ruby -Ilib test/test_shim_consistency.rb
require "minitest/autorun"
require "tmpdir"
require "yaml"
require "axum_dsl"

class TestShimConsistency < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  CATALOG = YAML.safe_load_file(File.join(ROOT, "spec/shims/string.yml")).freeze

  # Catalogue method names that are deliberately not in Body::ALLOWED_METHODS, with the reason. A
  # method name here is a promise that the body language reaches the behaviour some other way (or
  # not at all); a new out-of-scope name has to be added here on purpose.
  OUT_OF_SCOPE = {
    "to_lowercase" => "the Rust::Str method (receiver: rust_type), named as Rust names it; a body reaches " \
                      "it only through `Rust::Str(s)`, so it is not a method on a Ruby String (that name is `downcase`)",
    "len" => "the Rust::Str byte length (receiver: rust_type), reached only through `Rust::Str(s)`; " \
             "the Ruby-side name is `length` and it counts characters",
    "Integer" => "Kernel#Integer, which the body language handles as the call `Integer(text, 10)` " \
                 "(body.rb integer_call), not as a method on a value"
  }.freeze

  # A catalogue entry whose Rust cannot be driven through a route body, with the reason. Empty today:
  # every entry in spec/shims/string.yml is driven below.
  UNCOVERED = {}.freeze

  # entry name => [route body expression, the template's distinguishing text in the emitted Rust].
  # The expression is the body of a one-route probe service; the emitter is driven on it and the
  # needle has to be present in the src/main.rs it writes.
  DRIVEN = {
    # -- strip and case ----------------------------------------------------------------
    "String#strip" => ["text(params[:s].strip)",
                       %q(trim_matches(|c: char| matches!(c, '\u{0}' | '\t' | '\n' | '\u{b}' | '\u{c}' | '\r' | ' '))),
                       "Ruby's strip set (NUL, tab, LF, VT, FF, CR, space), not Rust's Unicode trim()"],
    "Rust::Str#strip" => ["text(Rust::Str(params[:s]).strip.to_s)", ".trim()",
                          "Rust::Str#strip is Rust trim()"],
    "String#downcase" => ["text(params[:s].downcase)", ".to_lowercase()", "downcase compiles to to_lowercase"],
    "Rust::Str#to_lowercase" => ["text(Rust::Str(params[:s]).to_lowercase.to_s)", ".to_lowercase()",
                                 "the Rust::Str spelling of the same operation"],
    # -- length ------------------------------------------------------------------------
    "String#length" => ["text(params[:s].length.to_s)", ".chars().count() as i64",
                        "characters, not bytes (Rust len())"],
    "Rust::Str#len" => ["text(Rust::Str(params[:s]).len.to_s)", ".len() as i64",
                        "Rust::Str#len is the byte length, as Rust's len() is"],
    # -- replacement -------------------------------------------------------------------
    "String#gsub(string, string)" => ['text(params[:s].gsub("a", "b"))', ".replace(",
                                      "a literal pattern and replacement is str::replace"],
    "String#sub(string, string)" => ['text(params[:s].sub("a", "b"))', ".replacen(",
                                     "one replacement is str::replacen(.., 1)"],
    "String#gsub(regex, string)" => ['text(params[:s].gsub(/a/, "b"))', "replace_all(",
                                     "a translated regex and a literal replacement is Regex::replace_all(NoExpand(..))"],
    "String#sub(regex, string)" => ['text(params[:s].sub(/a/, "b"))', "replace(",
                                    "one regex replacement is Regex::replace(NoExpand(..))"],
    # -- split -------------------------------------------------------------------------
    "String#split.length" => ["text(params[:s].split.length.to_s)", ".filter(|w| !w.is_empty())",
                              "awk-style split drops empty pieces before counting"],
    "String#split(string).length" => ['text(params[:s].split(",").length.to_s)', "to_string()).collect(); while ",
                                      "split(string) drops trailing empties, as Ruby does"],
    "String#split(string).first" => ['text(params[:s].split(",").first.to_s)', "to_string()).collect(); while ",
                                     "the same split, then the first piece"],
    "String#split(string).last" => ['text(params[:s].split(",").last.to_s)', "to_string()).collect(); while ",
                                    "the same split, then the last piece"],
    "String#split(string, int).length" => ['text(params[:s].split(",", 2).length.to_s)', ".splitn(",
                                           "a positive limit splits with str::splitn"],
    "String#split(string, int).last" => ['text(params[:s].split(",", 2).last.to_s)', ".splitn(",
                                         "the same splitn, then the last piece"],
    # -- tests -------------------------------------------------------------------------
    "String#start_with?" => ['text(params[:s].start_with?("a").to_s)', ".starts_with(", "prefix test"],
    "String#end_with?" => ['text(params[:s].end_with?("a").to_s)', ".ends_with(", "suffix test"],
    "String#include?" => ['text(params[:s].include?("a").to_s)', ".contains(", "substring test"],
    "String#empty?" => ["text(params[:s].empty?.to_s)", ".is_empty()", "emptiness test"],
    "String#match?(regex)" => ["text(params[:s].match?(/a/).to_s)", ".is_match(",
                               "an unanchored search is Regex::is_match"],
    # -- reorder, slice, index ---------------------------------------------------------
    "String#reverse" => ["text(params[:s].reverse)", ".chars().rev().collect::<String>()",
                         "reverse by code point, not by grapheme cluster"],
    "String#index(string)" => ['text(params[:s].index("x").to_s)', ".chars().count() as i64",
                               "the byte offset is mapped back to a character offset"],
    "String#[](int, int)" => ["text(params[:s][1, 2].to_s)", "s.chars().collect()",
                              "slicing counts characters, over a Vec<char>"],
    "String#[](int)" => ["text(params[:s][1].to_s)", "s.chars().collect()",
                         "single indexing counts characters too"],
    # -- character sets ----------------------------------------------------------------
    "String#tr" => ['text(params[:s].tr("a", "b"))', ".chars().map(|",
                    "tr maps each source character to its target character"],
    "String#delete" => ['text(params[:s].delete("a"))', ".chars().filter(|",
                        "delete keeps the characters not in the set"],
    "String#squeeze" => ["text(params[:s].squeeze)", ": Option<char> = None; for ",
                         "squeeze collapses a run of the same character"],
    # -- capitalize, lines, partition --------------------------------------------------
    "String#capitalize" => ["text(params[:s].capitalize)",
                            "f.to_uppercase().collect::<String>() + &cs.as_str().to_lowercase()",
                            "first character titlecased, the rest downcased"],
    "String#lines.length" => ["text(params[:s].lines.length.to_s)", %q(.split_inclusive('\n')),
                              "lines splits after every newline and keeps it"],
    "String#partition(string).first" => ['text(params[:s].partition(",").first.to_s)', ".find(",
                                         "partition finds the separator, then takes what precedes it"],
    "String#partition(string).last" => ['text(params[:s].partition(",").last.to_s)', ".find(",
                                        "the same find, then what follows the separator"],
    # -- to_i, Integer and repeat ------------------------------------------------------
    "String#to_i" => ["text(params[:s].to_i.to_s)", "str_to_i(",
                      "Ruby's parsing rules live in the pasted str_to_i helper"],
    "Integer(string, 10)" => ["text(Integer(params[:s], 10).to_s)", "str_to_int(",
                              "the strict parser lives in the pasted str_to_int helper"],
    "String#*" => ["text(params[:s] * 2)", ".repeat(",
                   "a negative count is an error result, otherwise str::repeat"],
    # -- regex with a block ------------------------------------------------------------
    "String#gsub(regex) { bracket }" => ["text(params[:s].gsub(/a/) { |m| m })", "&regex::Captures",
                                         "the block gets the captured text as a regex::Captures"],
    "String#sub(regex) { bracket }" => ["text(params[:s].sub(/a/) { |m| m })", "&regex::Captures",
                                        "the same block form for one replacement"],
    "String#gsub(regex) { upcase }" => ["text(params[:s].gsub(/[a-z]+/) { |m| m.upcase })", "to_uppercase()",
                                        "the block's upcase compiles to to_uppercase()"]
  }.freeze

  def test_the_catalog_and_the_checks_cover_the_same_entries
    names = CATALOG.map { |e| e["name"] }
    checked = DRIVEN.keys + UNCOVERED.keys
    missing = names - checked
    assert_empty missing, "spec/shims/string.yml has entries nothing checks; add each to DRIVEN " \
                          "(with a snippet and a needle) or to UNCOVERED (with a reason): #{missing.join(', ')}"
    stale = checked - names
    assert_empty stale, "DRIVEN/UNCOVERED name entries the catalogue no longer has: #{stale.join(', ')}"
  end

  def test_every_catalog_method_name_is_known_or_out_of_scope
    methods = CATALOG.flat_map { |e| Array(e["method"]) }.map(&:to_s).uniq
    unknown = methods - AxumDsl::Body::ALLOWED_METHODS - OUT_OF_SCOPE.keys
    assert_empty unknown, "spec/shims/string.yml names methods neither Body::ALLOWED_METHODS nor " \
                          "OUT_OF_SCOPE knows: #{unknown.join(', ')}"
    stale = OUT_OF_SCOPE.keys - methods
    assert_empty stale, "OUT_OF_SCOPE names methods the catalogue no longer declares: #{stale.join(', ')}"
  end

  def test_the_emitter_spells_each_catalog_template
    failures = []
    DRIVEN.each do |name, (expr, needle, what)|
      entry = CATALOG.find { |e| e["name"] == name }
      refute_nil entry, "DRIVEN names #{name}, which the catalogue does not have"
      main = emit_one(expr)
      unless main.include?(needle)
        failures << "#{name}: the emitted Rust has no #{needle.inspect} (#{what}); " \
                    "the emitter and spec/shims/string.yml have drifted apart"
      end
      next unless entry["helper"]

      const = entry["helper"].upcase
      unless AxumDsl::Emit.const_defined?(const, false)
        failures << "#{name}: names helper `#{entry['helper']}`, but AxumDsl::Emit has no #{const} constant"
        next
      end
      helper = AxumDsl::Emit.const_get(const, false)
      unless main.include?(helper)
        failures << "#{name}: the emitter does not paste the #{const} helper verbatim, so this file " \
                    "and AxumDsl::Emit disagree about the helper's Rust"
      end
    end
    assert_empty failures, "the emitter drifts from spec/shims/string.yml:\n  #{failures.join("\n  ")}"
  end

  private

  # Emit one route whose body is `expr`, and return the src/main.rs. The probe is written to a temp
  # dir (as test_routes.rb does); the emitter is driven on it, never a hand-written Rust string
  # compared against another hand-written one.
  def emit_one(expr)
    Dir.mktmpdir("shim") do |dir|
      file = File.join(dir, "probe.axum.rb")
      File.write(file, <<~RB)
        server "shimprobe", version: "0.1.0"
        set :port, 4567

        params :One do
          field :s, :string, in: :query
        end

        get "/probe", params: :One do
          #{expr}
        end
      RB
      AxumDsl::Emit.files(AxumDsl.read(file), file).fetch("src/main.rs")
    end
  end
end
