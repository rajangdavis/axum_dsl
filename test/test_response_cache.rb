# frozen_string_literal: true

# `get ..., cache: :private` (WAVE-PLAN AP1): what the compiler emits for the response cache and when it writes
# nothing. No cargo and no HTTP; the refusal halves live under test/refusals/cache_*.rb and the behaviour over
# HTTP is campfire_axum_dsl/test/e2e_campfire.sh.
#
#   ruby -Ilib test/test_response_cache.rb
require "minitest/autorun"
require "tmpdir"
require "axum_dsl"

class TestResponseCache < Minitest::Test
  HEAD = <<~RB
    server "cached", version: "0.1.0"
    set :port, 8080
    database :sqlite, path: "x.db", env: "DB_PATH"
    query :one, args: {}, returns: :i64, sql: "SELECT 1"
  RB

  def files(body, head: HEAD)
    Dir.mktmpdir("cache") do |dir|
      file = File.join(dir, "cached.axum.rb")
      File.write(file, head + body)
      AxumDsl::Emit.files(AxumDsl.read(file), file)
    end
  end

  ROUTES = <<~RB
    params :RoomPath do
      field :id, :string, in: :path
    end

    get "/rooms/:id", params: :RoomPath, cache: :private do
      "room"
    end

    get "/plain" do
      "plain \#{one()}"
    end
  RB

  def test_a_cached_route_looks_up_first_and_admits_last
    main = files(ROUTES).fetch("src/main.rs")
    assert_includes main, "const AXUM_DSL_CACHE_ROUTES: &[&str] = &[\"/rooms/{id}\"];"
    assert_includes main, "axum_dsl_cache_lookup(\"/rooms/{id}\", __cache_ticket.0"
    assert_includes main, "axum_dsl_cache_admit(__cache_admit, response).await"
    assert_includes main, "axum_dsl_cache_open(&path, 64)?;"
    assert_includes main, ".layer(::axum::middleware::from_fn(axum_dsl_cache_begin))"
    assert_includes main, "SQLITE_OPEN_READ_ONLY"
    assert_equal 1, main.scan("axum_dsl_cache_lookup(\"").size, "the plain route must not look anything up"
    assert_includes files(ROUTES).fetch("Cargo.toml"), "sha2 = \"0.10\""
  end

  def test_the_cache_layer_is_outside_every_before_filter
    main = files("before :guard do\n  \"continue\"\nend\n#{ROUTES}").fetch("src/main.rs")
    assert_operator main.index("from_fn(before_1)"), :<, main.index("from_fn(axum_dsl_cache_begin)")
  end

  def test_a_declared_setting_sizes_the_cache
    sized = HEAD + "setting :response_cache_mb, env: \"CACHE_MB\", default: 8, type: :i64\n"
    main = files(ROUTES, head: sized).fetch("src/main.rs")
    assert_includes main, "axum_dsl_cache_open(&path, settings().response_cache_mb)?;"
  end

  def test_a_crate_without_cache_routes_has_none_of_it
    files = files("get \"/plain\" do\n  \"plain \#{one()}\"\nend\n")
    refute_includes files.fetch("src/main.rs"), "axum_dsl_cache"
    refute_includes files.fetch("Cargo.toml"), "sha2"
    refute_includes files.fetch("Cargo.toml"), "flate2"
  end

  def test_without_front_an_entry_is_stored_identity
    main = files(ROUTES).fetch("src/main.rs")
    assert_includes main, "const AXUM_DSL_CACHE_GZIP: bool = false;"
  end

  def test_a_conditional_statement_runs_an_effect_only_when_true
    main = files(<<~RB).fetch("src/main.rs")
      get "/conditional" do
        on = true
        if on
          one()
        end
        "ok"
      end
    RB
    assert_includes main, "if on {"
    assert_includes main, "one()"
  end

  def test_a_conditional_statement_compiles_without_a_guard
    main = files(<<~RB).fetch("src/main.rs")
      get "/conditional" do
        on = true
        if on
          one()
        end
        "ok"
      end
    RB
    assert_includes main, "if on {"
  end

  def test_a_conditional_statement_is_allowed_inside_a_transaction
    main = files(<<~RB).fetch("src/main.rs")
      get "/conditional-transaction" do
        on = true
        value = transaction do
          if on
            one()
          end
          one()
        end
        "ok \#{value}"
      end
    RB
    assert_includes main, "if on {"
  end

  def test_with_front_a_gzip_entry_is_stored_compressed_at_admission
    generated = files("use_layer :front\n#{ROUTES}")
    main = generated.fetch("src/main.rs")
    assert_includes main, "const AXUM_DSL_CACHE_GZIP: bool = true;"
    assert_includes main, "axum_dsl_cache_accepts_gzip"
    assert_includes main, "GzEncoder::new(Vec::new()"
    assert_includes main, "content-encoding\", ::axum::http::HeaderValue::from_static(\"gzip\")"
    assert_equal 1, generated.fetch("Cargo.toml").scan(/^flate2 = /).size, "the shared deflate dependency must appear once"
  end
end
