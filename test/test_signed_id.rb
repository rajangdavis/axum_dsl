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
end
