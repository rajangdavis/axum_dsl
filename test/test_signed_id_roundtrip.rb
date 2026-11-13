# frozen_string_literal: true

# The Rails signing runtime (lib/axum_dsl/signed_id.rb) compiled and run: a token `rails_signed_id_for` makes
# verifies with `rails_signed_id` (the verifier Campfire's avatar route uses), equals the bytes Rails minted for
# the same secret, id and purpose, and the Turbo stream name, GlobalID param and urlsafe base64 are what
# turbo-rails, GlobalID and Ruby's Base64 write. The expected values are computed here with OpenSSL (the
# MessageVerifier format: base64 of the payload, `--`, the lower-case hex HMAC-SHA256 of that base64 text, keyed by
# PBKDF2-HMAC-SHA256(secret, salt, 1000, 64)), independent of the Rust. Skipped when there is no cargo.
#
#   ruby -Ilib test/test_signed_id_roundtrip.rb
require "minitest/autorun"
require "tmpdir"
require "open3"
require "openssl"
require "json"
require "axum_dsl"

class TestSignedIdRoundtrip < Minitest::Test
  SECRET = "0123456789abcdef0123456789abcdef0123456789"
  # Minted by Rails 8.2 (bin/rails runner "puts ActiveRecord::Base.signed_id_verifier.generate(2, purpose: %(user/avatar))")
  # with SECRET_KEY_BASE above; the same fixture campfire_axum_dsl/test/e2e_campfire.sh pins.
  RAILS_TOKEN = "eyJfcmFpbHMiOnsiZGF0YSI6MiwicHVyIjoidXNlci9hdmF0YXIifX0--e7ec9b3f880c3bdd75157af8dc8dcc5b5a896f22a34063545c6df0663e7206c2"

  MAIN = <<~RS
    fn main() {
        let secret = #{SECRET.inspect}.as_bytes();
        let token = axum_dsl_rails_signed_id_for(secret, 2, "user/avatar");
        println!("{token}");
        println!("{:?}", axum_dsl_rails_signed_id(secret, &token, "user/avatar", false));
        println!("{:?}", axum_dsl_rails_signed_id(secret, &token, "user/other", false));
        println!("{:?}", axum_dsl_rails_signed_id(secret, #{RAILS_TOKEN.inspect}, "user/avatar", false));
        println!("{}", axum_dsl_turbo_signed_stream_name(secret, "Z2lkOi8vY2FtcGZpcmUvUm9vbXM6Ok9wZW4vMQ:messages"));
        println!("{}", axum_dsl_global_id_param("campfire", "Rooms::Open", 1));
        println!("{}", axum_dsl_urlsafe_base64("http://x/?>?"));
        println!("{:?}", axum_dsl_rails_signed_id(secret, %FUTURE%, "user/avatar", true));
        println!("{:?}", axum_dsl_rails_signed_id(secret, %PAST%, "user/avatar", true));
        println!("{:?}", axum_dsl_rails_signed_id(secret, &token, "user/avatar", true));
        println!("{:?}", axum_dsl_rails_signed_id(secret, %FUTURE%, "user/avatar", false));
    }
  RS

  def self.pbkdf2(salt) = OpenSSL::PKCS5.pbkdf2_hmac(SECRET, salt, 1000, 64, "sha256")

  def self.sign(salt, data) = "#{data}--#{OpenSSL::HMAC.hexdigest('SHA256', pbkdf2(salt), data)}"

  # A metadata token with an `exp`, signed the way Rails and the emitted verifier sign it. The dates are fixed
  # rather than relative so the test still names one future and one past expiry years from now.
  def self.token(exp)
    data = { "_rails" => { "data" => 2, "exp" => exp, "pur" => "user/avatar" } }.to_json
    sign("active_record/signed_id", [data].pack("m0").tr("+/", "-_").delete("="))
  end

  def run_rust
    skip "no cargo" unless system("cargo --version", out: File::NULL, err: File::NULL)

    # active_storage_disk_upload is a request handler (axum's HeaderMap, tokio's file writes), not a signing primitive:
    # the bare crate here has neither, and Campfire's crate builds and exercises it.
    ir = { "builtins" => AxumDsl::SignedId::BUILTINS - [AxumDsl::SignedId::DISK_UPLOAD] }
    Dir.mktmpdir("signed_id_rt") do |dir|
      Dir.mkdir(File.join(dir, "src"))
      File.write(File.join(dir, "Cargo.toml"), <<~TOML)
        [package]
        name = "signed_id_rt"
        version = "0.1.0"
        edition = "2021"

        [dependencies]
        serde_json = "1"#{AxumDsl::SignedId.deps(ir)}
      TOML
      main = MAIN.gsub("%FUTURE%", self.class.token("2099-01-01T00:00:00.000Z").inspect)
                 .gsub("%PAST%", self.class.token("2000-01-01T00:00:00.000Z").inspect)
      File.write(File.join(dir, "src/main.rs"), "#![allow(dead_code)]\n#{AxumDsl::SignedId.items(ir).join("\n")}\n#{main}")
      AxumDsl::Lockfile.pin(dir, AxumDsl::Emit::VETTED_LOCK) # the same crates the emitter names, from the vetted set
      out, err, status = Open3.capture3("cargo", "run", "--quiet", "--locked", chdir: dir)
      assert status.success?, err
      out.lines.map(&:chomp)
    end
  end

  def test_the_runtime_agrees_with_openssl_and_with_the_rails_fixture
    token, own, wrong_purpose, rails, stream, gid, urlsafe, future_ok, past_nil, no_exp_ok, unchecked_nil = run_rust

    payload = ['{"_rails":{"data":2,"pur":"user/avatar"}}'].pack("m0").tr("+/", "-_").delete("=")
    assert_equal self.class.sign("active_record/signed_id", payload), token, "the token is the MessageVerifier format"
    assert_equal RAILS_TOKEN, token, "the bytes are the ones Rails minted"
    assert_equal "Some(2)", own, "our verifier accepts what we generate"
    assert_equal "None", wrong_purpose
    assert_equal "Some(2)", rails, "our verifier accepts Rails' token"
    assert_equal "Some(2)", future_ok, "check_expiry: true accepts an exp in the future"
    assert_equal "None", past_nil, "check_expiry: true refuses an exp in the past"
    assert_equal "Some(2)", no_exp_ok, "check_expiry: true accepts a token with no exp"
    assert_equal "None", unchecked_nil, "without check_expiry a non-null exp is still refused"

    name = "Z2lkOi8vY2FtcGZpcmUvUm9vbXM6Ok9wZW4vMQ:messages"
    assert_equal self.class.sign("turbo/signed_stream_verifier_key", [name.to_json].pack("m0")), stream
    assert_equal ["gid://campfire/Rooms::Open/1"].pack("m0").tr("+/", "-_").delete("="), gid
    assert_equal "aHR0cDovL3gvPz4_", urlsafe
    assert_equal ["http://x/?>?"].pack("m0").tr("+/", "-_"), urlsafe
  end
end
