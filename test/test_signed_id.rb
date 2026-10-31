# frozen_string_literal: true

# `rails_signed_id(token, purpose:, secret:)`: the Rails 8 signed-ID verifier in the emitted crate. These
# tests pin the wire format's moving parts and the refusals; the runtime itself is exercised over HTTP by
# campfire_axum_dsl/test/e2e_campfire.sh, which gets its token from ActiveSupport or a fixed Rails token.
#
#   ruby -Ilib test/test_signed_id.rb
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "axum_dsl"

class TestSignedId < Minitest::Test
  HEAD = <<~RB
    server "signed", version: "0.1.0"
    setting :secret_key, env: "SECRET_KEY_BASE", secret: true
  RB

  def files(body, head: HEAD)
    Dir.mktmpdir("signed") do |dir|
      file = File.join(dir, "signed.axum.rb")
      File.write(file, head + body)
      AxumDsl::Emit.files(AxumDsl.read(file), file)
    end
  end

  def refusal(body, head: HEAD)
    error = assert_raises(AxumDsl::CompileError) { files(body, head: head) }
    error.message
  end

  def body(call = 'rails_signed_id(params[:token], purpose: "user/avatar", secret: :secret_key)')
    <<~RB
      params :TokenPath do
        field :token, :string, in: :path
      end

      get "/users/:token", params: :TokenPath do
        id = #{call}
        return halt(404, "") if id.nil?
        text(id.to_s)
      end
    RB
  end

  def test_the_verifier_is_the_rails_8_metadata_verifier
    main = files(body).fetch("src/main.rs")
    assert_includes main, 'b"active_record/signed_id"', "the key salt is the message verifiers salt"
    assert_includes main, "::pbkdf2::pbkdf2::<::hmac::Hmac<::sha2::Sha256>>"
    assert_includes main, "::hmac::Hmac::<::sha2::Sha256>::new_from_slice"
    assert_includes main, "verify_slice(&tag)", "the HMAC is checked in constant time"
    assert_includes main, "URL_SAFE_NO_PAD"
    assert_includes main, 'outer.get("_rails")'
    assert_includes main, 'rails.get("pur")'
    assert_includes main, 'rails.get("data")?.as_i64()'
  end

  def test_the_key_is_derived_once_per_process
    main = files(body).fetch("src/main.rs")
    assert_includes main, "static KEY: ::std::sync::OnceLock<[u8; 64]> = ::std::sync::OnceLock::new();"
    assert_includes main, "KEY.get_or_init(||"
    assert_includes main, "fn axum_dsl_signed_id_key(secret: &[u8]) -> &'static [u8; 64]"
    refute_includes main, "fn axum_dsl_signed_id_key(secret: &[u8]) -> [u8; 64]"
  end

  def test_json_object_and_json_array_build_a_record_response
    main = files(<<~RB, head: "server \"signed\", version: \"0.1.0\"\n").fetch("src/main.rs")
      get "/users.json" do
        items = ["a", "b"].map { |name| json_object("name" => name, "value" => 1) }
        text(json_array(items), content_type: "application/json")
      end
    RB
    assert_includes main, "::serde_json::json!({"
    assert_includes main, "format!(\"[{}]\","
  end

  def test_a_signed_global_id_is_the_globalid_verifier
    main = files(<<~RB, head: HEAD).fetch("src/main.rs")
      get "/sgid" do
        rails_signed_global_id("User", 1, app: "campfire", secret: :secret_key)
      end
    RB
    assert_includes main, "b\"signed_global_ids\""
    assert_includes main, "?expires_in"
    assert_includes main, "::hmac::Hmac::<::sha1::Sha1>"
    assert_includes main, "general_purpose::URL_SAFE.encode"
    assert_includes main, '"attachable"'
    assert_match(/^sha1 = /, files(<<~RB, head: HEAD).fetch("Cargo.toml"))
      get "/sgid" do
        rails_signed_global_id("User", 1, app: "campfire", secret: :secret_key)
      end
    RB
  end

  def test_the_cargo_lines_are_the_dependencies_the_verifier_names
    cargo = files(body).fetch("Cargo.toml")
    %w[hmac sha2 pbkdf2 base64].each do |crate|
      assert_match(/^#{crate} = /, cargo, "the generated Cargo.toml has #{crate}")
    end
  end

  def test_the_runtime_is_absent_until_a_body_uses_it
    main = files(<<~RB, head: "server \"signed\", version: \"0.1.0\"\n").fetch("src/main.rs")
      get "/" do
        "ok"
      end
    RB
    refute_includes main, "axum_dsl_rails_signed_id"
  end

  def test_check_expiry_is_a_boolean_keyword_that_defaults_to_false
    main = files(body).fetch("src/main.rs")
    assert_includes main,
                    "fn axum_dsl_rails_signed_id(secret: &[u8], token: &str, purpose: &str, check_expiry: bool) -> Option<i64>"
    assert_includes main, ', "user/avatar", false)', "without the keyword the verifier refuses any exp"
    assert_includes main, "fn axum_dsl_iso8601_ms(", "the verifier's own function names the clock formatter in its check branch"
  end

  def test_check_expiry_true_checks_the_expiry_and_emits_the_formatter
    main = files(body('rails_signed_id(params[:token], purpose: "user/avatar", secret: :secret_key, check_expiry: true)')).fetch("src/main.rs")
    assert_includes main, ', "user/avatar", true)'
    assert_includes main, "fn axum_dsl_iso8601_ms(", "the verifier compares exp with the formatter the generator uses"
    assert_includes main, "if !check_expiry {", "without the keyword a non-null exp is still refused"
    assert_includes main, "if expires <= axum_dsl_iso8601_ms(now).as_str() {", "a fixed-width iso8601 string compares as text"
  end

  def test_check_expiry_must_be_written_out
    message = refusal(body('rails_signed_id(params[:token], purpose: "user/avatar", secret: :secret_key, check_expiry: "yes")'))
    assert_includes message, "`check_expiry:` is true or false"
  end

  def test_a_missing_secret_is_refused
    message = refusal(body('rails_signed_id(params[:token], purpose: "user/avatar")'))
    assert_includes message, "needs `purpose:` and `secret:`"
  end

  def test_an_unknown_secret_is_refused
    message = refusal(body('rails_signed_id(params[:token], purpose: "user/avatar", secret: :nope)'))
    assert_includes message, "no setting `nope` is declared"
  end

  def test_an_optional_secret_is_refused
    head = "server \"signed\", version: \"0.1.0\"\nsetting :open_key, env: \"OPEN_KEY\", optional: true\n"
    message = refusal(body('rails_signed_id(params[:token], purpose: "user/avatar", secret: :open_key)'), head: head)
    assert_includes message, "must name a required string setting"
  end

  def test_the_purpose_is_a_nonempty_string_literal
    message = refusal(body('rails_signed_id(params[:token], purpose: :avatar, secret: :secret_key)'))
    assert_includes message, "`purpose:` is a string literal"
  end

  def test_the_token_is_a_string
    message = refusal(body("rails_signed_id(1, purpose: \"user/avatar\", secret: :secret_key)"))
    assert_includes message, "takes a token string"
  end

  def test_unknown_keywords_are_refused
    message = refusal(body('rails_signed_id(params[:token], purpose: "user/avatar", secret: :secret_key, model: :user)'))
    assert_includes message, "unknown keyword `model:`"
  end

  def test_two_different_secrets_are_refused
    head = HEAD + "setting :other_key, env: \"OTHER_KEY\", secret: true\n"
    body = <<~RB
      params :TokenPath do
        field :token, :string, in: :path
      end

      get "/a/:token", params: :TokenPath do
        id = rails_signed_id(params[:token], purpose: "user/avatar", secret: :secret_key)
        return halt(404, "") if id.nil?
        text(id.to_s)
      end

      get "/b/:token", params: :TokenPath do
        id = rails_signed_id(params[:token], purpose: "user/avatar", secret: :other_key)
        return halt(404, "") if id.nil?
        text(id.to_s)
      end
    RB
    message = refusal(body, head: head)
    assert_includes message, "already uses setting `secret_key`"
  end

  # --- generation (rails_signed_id_for) and the other signing calls ---------------------------------------------

  def route(call, kind = "text")
    <<~RB
      params :IdPath do
        field :id, :i64, in: :path
      end

      get "/t/:id", params: :IdPath do
        #{kind}(#{call})
      end
    RB
  end

  def test_generation_writes_the_rails_envelope_and_not_the_verifier
    main = files(route('rails_signed_id_for(params[:id], purpose: "user/avatar", secret: :secret_key)')).fetch("src/main.rs")
    assert_includes main, "fn axum_dsl_rails_signed_id_for(secret: &[u8], id: i64, purpose: &str) -> String"
    assert_includes main, '"{{\"_rails\":{{\"data\":{},\"pur\":{}}}}}"', "the metadata envelope"
    assert_includes main, "URL_SAFE_NO_PAD.encode(json.as_bytes())", "url_safe: true, unpadded"
    assert_includes main, 'format!("{data}--{digest}")'
    assert_includes main, "axum_dsl_rails_signed_id_for(settings().secret_key.as_bytes(), "
    assert_includes main, '"user/avatar")'
    assert_includes main, 'b"active_record/signed_id"', "the same key as the verifier"
    refute_includes main, "fn axum_dsl_rails_signed_id(", "a generate-only service carries no verifier"
    refute_includes main, "turbo/signed_stream_verifier_key"
  end

  def test_generation_and_verification_share_one_key_function
    main = files(body + route('rails_signed_id_for(params[:id], purpose: "user/avatar", secret: :secret_key)').sub("/t/", "/u/")).fetch("src/main.rs")
    assert_equal 1, main.scan("fn axum_dsl_signed_id_key(").size
    assert_includes main, "fn axum_dsl_rails_signed_id("
    assert_includes main, "fn axum_dsl_rails_signed_id_for("
  end

  def test_generation_refusals
    message = refusal(route('rails_signed_id_for("1", purpose: "user/avatar", secret: :secret_key)'))
    assert_includes message, "takes an integer id"
    message = refusal(route("rails_signed_id_for(params[:id], secret: :secret_key)"))
    assert_includes message, "needs `purpose:` and `secret:`"
    message = refusal(route('rails_signed_id_for(params[:id], purpose: :avatar, secret: :secret_key)'))
    assert_includes message, "`purpose:` is a string literal"
    message = refusal(route('rails_signed_id_for(params[:id], purpose: "user/avatar", secret: :nope)'))
    assert_includes message, "no setting `nope` is declared"
    message = refusal(route('rails_signed_id_for(params[:id], purpose: "user/avatar", secret: :secret_key, model: :user)'))
    assert_includes message, "unknown keyword `model:`"
  end

  def test_expires_in_writes_the_exp_between_data_and_pur
    main = files(route('rails_signed_id_for(params[:id], purpose: "user/transfer", secret: :secret_key, expires_in: 14400)')).fetch("src/main.rs")
    assert_includes main, "fn axum_dsl_rails_signed_id_for_expiring(secret: &[u8], id: i64, purpose: &str, expires_in: i64) -> String"
    assert_includes main, '"{{\"_rails\":{{\"data\":{},\"exp\":\"{}\",\"pur\":{}}}}}"', "Rails orders data, exp, pur"
    assert_includes main, "fn axum_dsl_iso8601_ms(", "the expiry is ISO 8601 with milliseconds"
    assert_includes main, '"user/transfer", 14400)'
    refute_includes main, "fn axum_dsl_rails_signed_id_for(", "an expiring-only service carries no plain generator"
    refute_includes main, "fn axum_dsl_rails_signed_id(", "nor a verifier"
  end

  def test_expires_in_refusals
    message = refusal(route('rails_signed_id_for(params[:id], purpose: "user/transfer", secret: :secret_key, expires_in: "4h")'))
    assert_includes message, "`expires_in:` is a positive integer literal"
    message = refusal(route('rails_signed_id_for(params[:id], purpose: "user/transfer", secret: :secret_key, expires_in: 0)'))
    assert_includes message, "`expires_in:` is a positive integer literal"
  end

  def test_one_secret_serves_generation_and_the_turbo_stream_name
    head = HEAD + "setting :other_key, env: \"OTHER_KEY\", secret: true\n"
    call = 'turbo_signed_stream_name(:rooms, secret: :other_key)'
    message = refusal(body + route(call).sub("/t/", "/u/"), head: head)
    assert_includes message, "already uses setting `secret_key`"
  end

  def test_the_turbo_stream_name_is_turbo_rails_strict_base64_json
    main = files(route('turbo_signed_stream_name(global_id_param("Rooms::Open", params[:id], app: "campfire"), :messages, secret: :secret_key)')).fetch("src/main.rs")
    assert_includes main, 'b"turbo/signed_stream_verifier_key"'
    assert_includes main, "STANDARD.encode(json.as_bytes())", "strict (padded, standard) base64 of the JSON-dumped name"
    assert_includes main, 'axum_dsl_global_id_param("campfire", "Rooms::Open", '
    assert_includes main, ', "messages"].join(":")'
    assert_includes main, "fn axum_dsl_global_id_param(app: &str, model: &str, id: i64) -> String"
    refute_includes main, "fn axum_dsl_rails_signed_id", "no signed id runtime"
  end

  def test_turbo_and_global_id_refusals
    assert_includes refusal(route("turbo_signed_stream_name(secret: :secret_key)")), "takes the stream name's parts"
    assert_includes refusal(route("turbo_signed_stream_name(:rooms)")), "needs `secret:`"
    assert_includes refusal(route("turbo_signed_stream_name(1, secret: :secret_key)")), "a string or a symbol"
    assert_includes refusal(route('global_id_param("Rooms::Open", params[:id])')), "needs `app:`"
    assert_includes refusal(route('global_id_param("Rooms::Open", "1", app: "campfire")')), "id is an integer"
  end

  def test_urlsafe_base64_is_padded_and_needs_only_base64
    plain = %(server "signed", version: "0.1.0"\n) # no signing call reads a secret, so none is declared
    result = files(route('urlsafe_base64("http://x/?a")'), head: plain)
    assert_includes result.fetch("src/main.rs"), "fn axum_dsl_urlsafe_base64(text: &str) -> String"
    assert_includes result.fetch("src/main.rs"), "general_purpose::URL_SAFE.encode(text.as_bytes())"
    assert_match(/^base64 = /, result.fetch("Cargo.toml"))
    refute_match(/^pbkdf2 = /, result.fetch("Cargo.toml"), "no key derivation without a signing call")
    assert_includes refusal(route("urlsafe_base64(1)"), head: plain), "takes a string"
  end

  def view_files(marker, locals: "{ id: params[:id] }", head: HEAD)
    Dir.mktmpdir("signed") do |dir|
      FileUtils.mkdir_p(File.join(dir, "views"))
      File.write(File.join(dir, "views/page.html"), "<img src=\"/users/#{marker}/avatar\">\n")
      file = File.join(dir, "signed.axum.rb")
      File.write(file, head + <<~RB)
        params :IdPath do
          field :id, :i64, in: :path
        end

        get "/t/:id", params: :IdPath do
          render :page, locals: #{locals}
        end
      RB
      AxumDsl::Emit.files(AxumDsl.read(file), file)
    end
  end

  def test_the_view_marker_writes_the_generated_token
    main = view_files('{{ rails_signed_id id, purpose: "user/avatar", secret: :secret_key }}').fetch("src/main.rs")
    assert_includes main, 'axum_dsl_rails_signed_id_for(settings().secret_key.as_bytes(), '
    assert_includes main, '"user/avatar")'
    assert_includes main, "fn axum_dsl_rails_signed_id_for("
  end

  def test_the_view_marker_refuses_a_non_integer_and_a_bad_shape
    marker = '{{ rails_signed_id id, purpose: "user/avatar", secret: :secret_key }}'
    error = assert_raises(AxumDsl::CompileError) { view_files(marker, locals: '{ id: "x" }') }
    assert_includes error.message, "needs an integer"
    error = assert_raises(AxumDsl::CompileError) { view_files("{{ rails_signed_id id }}") }
    assert_includes error.message, "takes an integer local"
  end
end
