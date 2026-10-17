# frozen_string_literal: true

# L1 shim unit test (SPEC.md section 3). Runs every catalog example against real
# Ruby (native_ruby entries) or lib/rust (rust_type entries). No eval: entries name
# a receiver kind and a method, and the harness calls public_send.
#
#   ruby -Ilib test/test_shims_string.rb
require "minitest/autorun"
require "yaml"
require "rust"

CATALOG = YAML.safe_load_file(File.expand_path("../spec/shims/string.yml", __dir__))

# Named blocks a catalog entry can pass (`block: bracket`); the entry's Rust template does the same thing.
BLOCKS = { "bracket" => ->(m) { "[#{m}]" }, "upcase" => :upcase.to_proc }.freeze

class TestShimsString < Minitest::Test
  def self.recv_for(entry, str)
    case entry.fetch("receiver")
    when "native_ruby" then str
    when "rust_type" then Rust::Str.new(str)
    when "kernel" then Kernel # the text is passed as the first argument
    else raise "unknown receiver #{entry['receiver'].inspect} in #{entry['name']}"
    end
  end

  CATALOG.each do |entry|
    entry.fetch("examples").each_with_index do |ex, i|
      define_method("test_#{entry['name']}_#{i}".gsub(/\W+/, "_")) do
        input = ex.fetch("in")
        recv = self.class.recv_for(entry, input.fetch("s"))
        args = entry.fetch("args", []).map do |name|
          val = input.fetch(name)
          entry.fetch("regex_args", []).include?(name) ? Regexp.new(val) : val
        end
        args.unshift(input.fetch("s")) if entry["receiver"] == "kernel"
        chain = Array(entry.fetch("method")) # a chain like [split, length]; args go to the first call
        blk = entry["block"] && BLOCKS.fetch(entry["block"]) # entries with a block: the first call gets it
        run = -> { chain.each_with_index.reduce(recv) { |acc, (m, idx)| idx.zero? ? acc.public_send(m, *args, &blk) : acc.public_send(m) } }
        if ex["raises"] # an example where Ruby raises (named by `raises:`)
          assert_raises(Object.const_get(ex["raises"]), "#{entry['name']} with #{ex['in'].inspect}") { run.call }
          next
        end
        got = run.call
        got = got.to_s if got.is_a?(Rust::Str)
        if ex.fetch("out").nil?
          assert_nil got, "#{entry['name']} with #{ex['in'].inspect}"
        else
          assert_equal ex.fetch("out"), got, "#{entry['name']} with #{ex['in'].inspect}"
        end
      end
    end
  end

  def test_every_entry_has_examples_including_empty_input
    CATALOG.each do |entry|
      ins = entry.fetch("examples").map { |ex| ex.fetch("in").fetch("s") }
      assert_includes ins, "", "#{entry['name']} needs an empty-input example"
    end
  end

  def test_entries_with_differing_behaviour_declare_a_notification
    CATALOG.select { |e| e["name"].end_with?("#strip") }.each do |entry|
      assert entry["notify"], "#{entry['name']} must declare notify:"
    end
  end
end
