# frozen_string_literal: true

# Sessions (docs/sessions.md), proved by compiling small DSL strings and asserting on the emitted Rust: narrowing
# through `||`, the once-per-request plumbing of `current`, the runtime each piece emits only when it is used, the
# cookie format seam, and `set :rust, :none`. No cargo and no HTTP; test/e2e_login.sh drives the running service.
# The refusal halves live under test/refusals/ (cookie_without_cookies.rb, current_unused.rb, rust_none_*.rb, ...).
#
#   ruby -Ilib test/test_login.rb
require "minitest/autorun"
require "tmpdir"
require "openssl"
require "axum_dsl"

class TestLogin < Minitest::Test
  HEAD = <<~RB
    server "sess", version: "0.1.0"
    set :port, 8080
  RB

  COOKIES = <<~RB
    setting :secret_key, env: "SECRET_KEY_BASE"
    cookies secret: :secret_key
  RB

  # Compiles `body` (appended to the header) and returns the emitted files, { "src/main.rs" => ..., "Cargo.toml" => ... }.
  def compile(body, head: HEAD)
    Dir.mktmpdir("sess") do |dir|
      file = File.join(dir, "sess.axum.rb")
      File.write(file, head + body)
      AxumDsl::Emit.files(AxumDsl.read(file), file)
    end
  end

  def main(body, head: HEAD) = compile(body, head: head)["src/main.rs"]

  def refusal(body, head: HEAD)
    error = assert_raises(AxumDsl::CompileError) { compile(body, head: head) }
    error.message
  end

  OPTIONAL = <<~RB
    params :P do
      field :a, :string, optional: true
    end

  RB

  # --- narrowing through || ----------------------------------------------------------------------------

  def test_the_right_of_an_or_sees_the_local_non_nil
    rust = main(OPTIONAL + <<~RB)
      get "/x", params: :P do
        a = params[:a]
        long = a.nil? || a.length > 3
        long.to_s
      end
    RB
    assert_match(/match a\.clone\(\) \{ None => true, Some\(a\) => /, rust, "the Some arm binds a at its inner type: no unwrap")
    refute_includes rust, "unwrap()", "narrowing is panic-free"
  end

  def test_an_or_whose_right_does_not_read_the_local_binds_nothing
    rust = main(OPTIONAL + <<~RB)
      get "/x", params: :P do
        a = params[:a]
        (a.nil? || true).to_s
      end
    RB
    assert_match(/match a \{ None => true, Some\(_\) => true \}/, rust)
  end

  def test_only_a_nil_test_on_the_left_narrows
    message = refusal(OPTIONAL + <<~RB)
      get "/x", params: :P do
        a = params[:a]
        (!a.nil? || a.length > 3).to_s
      end
    RB
    assert_includes message, "this value may be nil", "`!a.nil? || rest` leaves a nil-able in rest"
  end

  def test_a_guard_with_an_or_narrows_the_statements_after_it
    rust = main(OPTIONAL + <<~RB)
      get "/x", params: :P do
        a = params[:a]
        return halt(400, "bad") if a.nil? || a.length > 3
        a
      end
    RB
    assert_match(/None => true, Some\(a\) => /, rust, "the guard still runs `rest`")
    assert_match(/let a = match a \{ Some\(__v\) => __v, None => return Ok\(/, rust, "past the guard a is a plain string")
  end

  def test_an_unless_guard_with_an_or_does_not_narrow
    message = refusal(OPTIONAL + <<~RB)
      get "/x", params: :P do
        a = params[:a]
        return halt(400, "bad") unless a.nil? || a.length > 3
        a
      end
    RB
    assert_match(/may be nil|must be a string|body must return a string/, message, "an unless guard proves nothing about a")
  end

  # --- current -----------------------------------------------------------------------------------------

  CURRENT = <<~RB
    current :who, returns: :string? do
      cookie(:who)
    end

    before do
      return redirect("/login") if current(:who).nil?
      "continue"
    end

    get "/me" do
      current(:who).to_s
    end
  RB

  def test_a_current_is_one_cell_per_request_read_with_get_or_try_init
    files = compile(COOKIES + CURRENT)
    rust = files["src/main.rs"]
    assert_includes rust, "struct AxumDslCurrents {"
    assert_includes rust, "who: ::tokio::sync::OnceCell<Option<String>>,"
    assert_equal 2, rust.scan(".get_or_try_init(").size, "the filter and the route each read the one cell"
    assert_includes rust, "request.extensions_mut().insert(::std::sync::Arc::new(AxumDslCurrents::default()));"
    assert_includes rust, "async fn axum_dsl_current_who(__headers: &::axum::http::HeaderMap",
                    "the block is its own function, run by the first read"
    assert_includes files["Cargo.toml"], ", \"sync\"]", "tokio's OnceCell needs its sync feature"
  end

  def test_the_cells_are_made_by_a_layer_outside_every_filter
    rust = main(COOKIES + CURRENT)
    filter = rust.index(".layer(axum::middleware::from_fn(before_1))")
    scope = rust.index(".layer(axum::middleware::from_fn(axum_dsl_current_scope))")
    refute_nil filter
    refute_nil scope
    assert_operator scope, :>, filter, "the last layer added is the outermost, so the filter finds the cells"
  end

  def test_a_filter_and_a_route_bind_what_they_read_of_the_request
    rust = main(COOKIES + CURRENT)
    assert_includes rust, "let __currents = request.extensions().get::<::std::sync::Arc<AxumDslCurrents>>().cloned().unwrap_or_default();"
    assert_includes rust, "::axum::Extension(__currents): ::axum::Extension<::std::sync::Arc<AxumDslCurrents>>"
    assert_includes rust, "__headers: ::axum::http::HeaderMap"
  end

  def test_a_service_with_no_current_has_none_of_it
    files = compile(COOKIES + "get \"/x\" do\n  cookie(:a).to_s\nend\n")
    refute_includes files["src/main.rs"], "AxumDslCurrents"
    refute_includes files["Cargo.toml"], "\"sync\""
  end

  def test_a_current_may_read_the_currents_above_it
    rust = main(COOKIES + <<~RB)
      current :first, returns: :string? do
        cookie(:a)
      end

      current :second, returns: :string? do
        current(:first)
      end

      get "/x" do
        current(:second).to_s
      end
    RB
    assert_includes rust, "__currents.first.get_or_try_init(|| axum_dsl_current_first(&__headers, __peer, &__currents))"
  end

  # --- the runtime is emitted only when used -------------------------------------------------------------

  def test_cookies_emit_the_hmac_runtime_and_its_crates_only_when_read
    files = compile(COOKIES + "get \"/x\" do\n  cookie(:a).to_s\nend\n")
    rust = files["src/main.rs"]
    assert_includes rust, "fn axum_dsl_cookie_verify("
    refute_includes rust, "fn axum_dsl_cookie_sign(", "nothing sets a cookie"
    refute_includes rust, "axum_dsl_apply_cookies"
    %w[hmac sha2 base64].each { |crate| assert_includes files["Cargo.toml"], "\n#{crate} = " }
    refute_includes files["Cargo.toml"], "\nrand = "
    refute_includes files["Cargo.toml"], "\nbcrypt = "
    assert_includes rust, "if settings().secret_key.len() < 32 {", "a short key stops the server as it starts"
  end

  def test_set_cookie_signs_and_writes_a_set_cookie_line
    rust = main(COOKIES + <<~RB)
      get "/x" do
        set_cookie :session_token, "v", http_only: true, same_site: :strict, permanent: true
        redirect("/")
      end
    RB
    assert_includes rust, 'axum_dsl_set_cookie("session_token", "v", true, "Strict", false, Some(631139040))'
    assert_includes rust, "axum_dsl_apply_cookies(&mut __stated, &__cookies);"
    assert_includes rust, "fn axum_dsl_cookie_sign("
    refute_includes rust, "fn axum_dsl_cookie_verify(", "nothing reads a cookie"
  end

  def test_delete_cookie_alone_needs_no_signing
    files = compile(COOKIES + "get \"/x\" do\n  delete_cookie :session_token\n  redirect(\"/\")\nend\n")
    assert_includes files["src/main.rs"], 'axum_dsl_delete_cookie("session_token")'
    refute_includes files["src/main.rs"], "axum_dsl_cookie_mac"
    refute_includes files["Cargo.toml"], "\nhmac = "
  end

  def test_random_token_and_bcrypt_bring_their_own_crates
    files = compile("get \"/t\" do\n  random_token\nend\n")
    assert_includes files["Cargo.toml"], "\nrand = \"0.9\""
    assert_includes files["src/main.rs"], "b\"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz\""
    refute_includes files["Cargo.toml"], "\nbcrypt = "

    files = compile(<<~RB)
      params :P do
        field :pw, :string, in: :query
      end

      get "/b", params: :P do
        Bcrypt.verify(params[:pw], Bcrypt.hash(params[:pw])).to_s
      end
    RB
    assert_includes files["Cargo.toml"], "\nbcrypt = \"0.17\""
    assert_includes files["src/main.rs"], "spawn_blocking", "bcrypt is CPU-heavy, so it runs on the blocking pool"
    assert_includes files["src/main.rs"], "::bcrypt::hash(plain, 12)", "cost 12, Rails' default"
    refute_includes files["Cargo.toml"], "\nrand = "
  end

  def test_request_ip_follows_the_forwarded_trace_layer
    plain = main("get \"/ip\" do\n  request_ip\nend\n")
    assert_includes plain, "fn axum_dsl_request_ip(_headers:", "the peer's address, unless a proxy is trusted"
    forwarded = main("use_layer :trace, forwarded: true\nget \"/ip\" do\n  request_ip\nend\n")
    assert_includes forwarded, "fn axum_dsl_request_ip(headers:", "the first X-Forwarded-For entry comes first"
    refute_includes plain, "fn axum_dsl_request_ip(headers:"
    assert_includes plain, "::axum::extract::ConnectInfo(__connect)"
  end

  def test_fetch_metadata_is_a_layer_that_needs_no_tower_http
    files = compile("use_layer :fetch_metadata\nget \"/x\" do\n  \"ok\"\nend\n")
    assert_includes files["src/main.rs"], ".layer(::axum::middleware::from_fn(axum_dsl_fetch_metadata))"
    assert_includes files["src/main.rs"], "cross-site request refused"
    refute_includes files["Cargo.toml"], "tower-http"
    assert_includes refusal("use_layer :fetch_metadata, secs: 5\nget \"/x\" do\n  \"ok\"\nend\n"), "takes no keywords"
  end

  def test_a_service_that_uses_none_of_it_emits_none_of_it
    rust = main("get \"/x\" do\n  \"ok\"\nend\n")
    %w[axum_dsl_cookie axum_dsl_random_token axum_dsl_request_ip axum_dsl_bcrypt axum_dsl_fetch_metadata AxumDslCurrents].each do |name|
      refute_includes rust, name
    end
  end

  # --- the cookie format seam ------------------------------------------------------------------------------

  # format: :rails is Rails' ActiveSupport::MessageVerifier value. The expected cookie is computed here from
  # Ruby's own Marshal, OpenSSL and Base64 (activesupport/message_verifier.rb and key_generator.rb), not from
  # the compiler's Rust: Base64.strict_encode64(Marshal.dump(value)) + "--" + HMAC-SHA1 in lower-case hex, with
  # the key PBKDF2-HMAC-SHA1(secret, "signed cookie", 1000, 64 bytes), the iteration count Rails' application
  # key generator uses (railties/lib/rails/application.rb).
  RAILS_SECRET = "0123456789abcdef0123456789abcdef0123456789"
  RAILS_VECTOR = "BAhJIgh0b2sGOgZFVA==--87e78c745a7a62ef517be4571bdf0b22eb074ace"

  def rails_cookie(secret, value)
    key = OpenSSL::PKCS5.pbkdf2_hmac(secret, "signed cookie", 1_000, 64, OpenSSL::Digest::SHA1.new)
    data = [Marshal.dump(value)].pack("m0")
    "#{data}--#{OpenSSL::HMAC.hexdigest(OpenSSL::Digest::SHA1.new, key, data)}"
  end

  # Rails' MessageVerifier#verified, written out again from the documented algorithm (not from the compiler's
  # Rust): verify the hex HMAC over the Base64 data, then Marshal.load it. A bad digest or key reads as nil.
  def rails_verify(secret, cookie)
    data, digest = cookie.split("--", 2)
    return nil unless digest && digest.length == 40

    key = OpenSSL::PKCS5.pbkdf2_hmac(secret, "signed cookie", 1_000, 64, OpenSSL::Digest::SHA1.new)
    return nil unless OpenSSL::HMAC.hexdigest(OpenSSL::Digest::SHA1.new, key, data) == digest

    Marshal.load(data.unpack1("m0"))
  end

  def test_hmac_is_the_default_and_rails_is_the_other_format
    assert_equal %w[hmac rails], AxumDsl::Cookies::FORMATS.keys
    hmac = AxumDsl::Cookies.backend("hmac")
    assert_equal ["hmac = \"0.12\"", "sha2 = \"0.10\"", "base64 = \"0.22\""], hmac.deps
    text = hmac.items(read: true, set: true).join("\n")
    assert_includes text, "URL_SAFE_NO_PAD"
    assert_includes text, "verify_slice", "the MAC is compared in constant time"
    rails = AxumDsl::Cookies.backend("rails")
    assert_equal ["hmac = \"0.12\"", "sha1 = \"0.10\"", "pbkdf2 = \"0.12\"", "base64 = \"0.22\""], rails.deps
    assert_includes rails.items(read: true, set: true).join("\n"), "b\"signed cookie\""
  end

  def test_the_rails_vector_is_the_message_verifier_value_rails_writes
    assert_equal RAILS_VECTOR, rails_cookie(RAILS_SECRET, "tok")
    assert_equal "tok", rails_verify(RAILS_SECRET, RAILS_VECTOR)
    tampered = RAILS_VECTOR.dup
    tampered[-1] = tampered[-1] == "0" ? "1" : "0"
    assert_nil rails_verify(RAILS_SECRET, tampered), "a changed digest does not verify"
    assert_nil rails_verify(RAILS_SECRET + "x", RAILS_VECTOR), "another key does not verify"
    dump = Marshal.dump("tok").bytes
    assert_equal [4, 8, 0x49, 0x22], dump.first(4), "Marshal.dump of a String opens with \\x04\\x08I\""
    assert_equal [6, 0x3a, 6, 0x45, 0x54], dump.last(5), "and ends with the :E (UTF-8) instance variable"
  end

  def test_format_rails_makes_the_message_verifier_the_declaration_default
    head = HEAD + "setting :secret_key, env: \"SECRET_KEY_BASE\"\ncookies secret: :secret_key, format: :rails\n"
    files = compile(<<~RB, head: head)
      get "/x" do
        set_cookie :session_token, "tok"
        cookie(:session_token).to_s
      end
    RB
    rust = files["src/main.rs"]
    assert_includes rust, "fn axum_dsl_cookie_sign_rails("
    assert_includes rust, "fn axum_dsl_cookie_verify_rails("
    assert_includes rust, "axum_dsl_set_cookie_rails(\"session_token\", \"tok\""
    assert_includes rust, "axum_dsl_cookie_rails(&__headers, \"session_token\")"
    assert_includes rust, "::pbkdf2::pbkdf2::<::hmac::Hmac<::sha1::Sha1>>(axum_dsl_cookie_key(), b\"signed cookie\", 1_000, &mut key)"
    assert_includes rust, "OpenSSL::HMAC.hexdigest"
    assert_includes rust, "[4u8, 8u8, b'I', b'\"']", "the Marshal header"
    assert_includes rust, "if value == 0 {", "Ruby's w_long: a zero length is the byte 0"
    assert_includes rust, "if value < 123 {", "and a short length is value + 5"
    assert_includes rust, "out.push((value + 5) as u8);"
    assert_includes rust, "out.push(bytes.len() as u8);", "a longer length leads with its byte count"
    assert_includes rust, "[6u8, b':', 6u8, b'E', b'T']", "the :E = UTF-8 instance variable Marshal.dump adds to a String"
    assert_includes rust, "end.checked_add(5)?", "a huge Marshal length cannot overflow the trailer check"
    assert_includes rust, "::base64::engine::general_purpose::STANDARD"
    assert_includes rust, "axum_dsl_cookie_quote(&axum_dsl_cookie_sign_rails(name, value))"
    refute_includes rust, "axum_dsl_cookie_mac", "the hmac format is not emitted for a rails-only service"
    assert_includes files["Cargo.toml"], "\npbkdf2 = \"0.12\""
    assert_includes files["Cargo.toml"], "\nsha1 = \"0.10\""
  end

  def test_a_cookie_call_may_pick_the_other_format
    rust = main(COOKIES + <<~RB)
      get "/x" do
        set_cookie :legacy, "tok", format: :rails
        set_cookie :plain, "v"
        cookie(:legacy, format: :rails).to_s + cookie(:plain).to_s
      end
    RB
    assert_includes rust, "axum_dsl_set_cookie_rails(\"legacy\", \"tok\""
    assert_includes rust, "axum_dsl_cookie_rails(&__headers, \"legacy\")"
    assert_includes rust, "axum_dsl_set_cookie(\"plain\", \"v\""
    assert_includes rust, "fn axum_dsl_cookie_sign(", "the declared hmac format is emitted too"
    assert_includes rust, "axum_dsl_cookie_sign_rails(", "and so is the call's rails override"
  end

  def test_unsigned_cookies_are_plain_and_need_no_mac
    files = compile(COOKIES + <<~RB)
      get "/x" do
        set_cookie :last_room, "lobby", signed: false
        cookie(:last_room, signed: false).to_s
      end
    RB
    rust = files["src/main.rs"]
    assert_includes rust, "fn axum_dsl_set_cookie_raw("
    assert_includes rust, "axum_dsl_set_cookie_raw(\"last_room\", \"lobby\""
    assert_includes rust, "fn axum_dsl_cookie_raw("
    assert_includes rust, "axum_dsl_cookie_raw(&__headers, \"last_room\")"
    assert_includes rust, "fn axum_dsl_cookie_quote("
    assert_includes rust, "fn axum_dsl_cookie_unquote("
    refute_includes rust, "axum_dsl_cookie_sign"
    refute_includes rust, "axum_dsl_cookie_verify"
    refute_includes rust, "axum_dsl_cookie_mac"
    %w[hmac sha2 base64 pbkdf2 sha1].each { |crate| refute_includes files["Cargo.toml"], "\n#{crate} = ", "a plain cookie needs no crypto crate" }
    assert_includes rust, "if settings().secret_key.len() < 32 {", "the declaration still names the key"
  end

  def test_an_unsigned_cookie_cannot_name_a_format
    message = refusal(COOKIES + "get \"/x\" do\n  set_cookie :a, \"v\", signed: false, format: :rails\n  \"ok\"\nend\n")
    assert_includes message, "`format:` applies to a signed cookie"
    message = refusal(COOKIES + "get \"/x\" do\n  cookie(:a, signed: false, format: :rails).to_s\nend\n")
    assert_includes message, "`format:` applies to a signed cookie"
  end

  def test_a_cookie_format_must_be_hmac_or_rails
    message = refusal("setting :secret_key, env: \"SECRET_KEY_BASE\"\ncookies secret: :secret_key, format: :json\n\nget \"/x\" do\n  cookie(:a).to_s\nend\n")
    assert_includes message, "`:json` is not one of :hmac :rails"
    message = refusal(COOKIES + "get \"/x\" do\n  cookie(:a, format: :json).to_s\nend\n")
    assert_includes message, "cookie `format:` is :hmac or :rails"
  end

  # --- set :rust, :none ------------------------------------------------------------------------------------

  def test_none_mode_keeps_subprocesses_and_the_default_keeps_injection
    assert_includes main(<<~RB, head: HEAD + "set :rust, :none\n"), "run_subprocess"
      cmd_fn :up, program: "tr", argv: ["a-z", "A-Z"], args: [:string], returns: :string, pass: :stdin

      get "/x" do
        rust(:up, "a")
      end
    RB
    assert_includes main(<<~RB), "pub fn shout"
      rust_item "pub fn shout(s: &str) -> String { s.to_uppercase() }"
      rust_fn :shout, args: [:string], returns: :string

      get "/x" do
        rust(:shout, "a")
      end
    RB
  end

  def test_none_mode_refuses_inline_rust_wherever_the_setting_is
    code = "rust_item \"pub fn shout(s: &str) -> String { s.to_uppercase() }\"\n"
    assert_includes refusal(code, head: HEAD + "set :rust, :none\n"), "`rust_item` injects Rust, which `set :rust, :none`"
    assert_includes refusal(code + "set :rust, :none\n"), "`rust_item` injects Rust, which `set :rust, :none`"
  end
end
