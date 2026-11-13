# frozen_string_literal: true

# `rate_limited?("name", to:, within:)`: Rails' rate_limit as a check in a filter or route body, so the filters
# before it (a ban check) answer first and uncounted.
#
#   ruby -Ilib test/test_rate_limited.rb
require "minitest/autorun"
require "tmpdir"
require "axum_dsl"

class TestRateLimited < Minitest::Test
  def main(body)
    Dir.mktmpdir("rl") do |dir|
      file = File.join(dir, "app.axum.rb")
      File.write(file, <<~RB)
        server "rl", version: "0.1.0"
        post "/session" do
          #{body}
        end
      RB
      AxumDsl::Emit.files(AxumDsl.read(file), file)["src/main.rs"]
    end
  end

  def test_counts_per_name_and_client_address
    out = main('return halt(429, "no") if rate_limited?("sessions", to: 10, within: 180)' "\n  " '"ok"')
    assert_includes out, 'axum_dsl_rate_limited("sessions", axum_dsl_request_ip(&__headers, __peer), 10, 180)'
    assert_includes out, "fn axum_dsl_rate_limited(name: &str, client: String, to: u64, within: u64) -> bool"
    assert_includes out, "fn axum_dsl_request_ip(", "the client address is request_ip's"
    # The count expires `within` after its first request, as the cache key's expires_in does.
    assert_includes out, ".or_insert((now.saturating_add(within), 0))"
    assert_includes out, "entry.1 > to"
  end

  def test_needs_a_literal_name_and_both_keywords
    err = assert_raises(AxumDsl::CompileError) { main('x = rate_limited?("x", to: 10)' "\n  " '"ok"') }
    assert_includes err.message, "`within:` is a positive whole number"
    err = assert_raises(AxumDsl::CompileError) { main('x = rate_limited?(to: 10, within: 5)' "\n  " '"ok"') }
    assert_includes err.message, "takes a literal name"
    err = assert_raises(AxumDsl::CompileError) { main('x = rate_limited?("x", to: 10, within: 5, per: 1)' "\n  " '"ok"') }
    assert_includes err.message, "takes only `to:` and `within:`"
  end

  def test_runtime_left_out_when_unused
    refute_includes main('"ok"'), "fn axum_dsl_rate_limited("
  end
end
