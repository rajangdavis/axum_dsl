# frozen_string_literal: true

# The web_push runtime (lib/axum_dsl/web_push.rb) compiled and run: the body `axum_dsl_wp_encrypt` seals is opened
# here with OpenSSL (RFC 8291 aes128gcm: ECDH with the subscription key, HKDF-SHA256 over its auth secret, AES-128-GCM),
# and the VAPID JWT `axum_dsl_wp_vapid` signs verifies with OpenSSL against the key's public half. Both are computed
# independently of the Rust. A key that is not a P-256 point is BadKey (the caller answers 1), one that is not Base64
# is Unreadable (0). The network half (axum_dsl_web_push) is not exercised. Skipped when there is no cargo.
#
#   ruby -Ilib test/test_web_push_roundtrip.rb
require "minitest/autorun"
require "tmpdir"
require "open3"
require "openssl"
require "json"
require "axum_dsl"

class TestWebPushRoundtrip < Minitest::Test
  AUDIENCE = "https://push.example.test"
  SUBJECT = "mailto:ops@example.test"
  PLAINTEXT = "{\"title\":\"hi\",\"body\":\"café\"}"

  def b64u(bytes) = [bytes].pack("m0").tr("+/", "-_").delete("=")

  def unb64u(text) = text.tr("-_", "+/").unpack1("m")

  def point(key) = key.public_key.to_octet_string(:uncompressed)

  def scalar(key) = key.private_key.to_s(2).rjust(32, "\0")

  def run_rust(p256dh, auth, vapid_private)
    skip "no cargo" unless system("cargo --version", out: File::NULL, err: File::NULL)

    ir = { "builtins" => [AxumDsl::WebPush::CALL] }
    main = <<~RS
      fn main() {
          match axum_dsl_wp_encrypt(#{p256dh.inspect}, #{auth.inspect}, #{PLAINTEXT.inspect}.as_bytes()) {
              AxumDslWpBody::Sealed(body) => println!("{}", axum_dsl_wp_b64url(&body)),
              _ => println!("none"),
          }
          println!("{}", axum_dsl_wp_vapid(#{AUDIENCE.inspect}, #{SUBJECT.inspect}, #{vapid_private.inspect}).unwrap_or_default());
          println!("{}", matches!(axum_dsl_wp_encrypt("AAAA", #{auth.inspect}, b"x"), AxumDslWpBody::BadKey));
          println!("{}", matches!(axum_dsl_wp_encrypt("!!!", #{auth.inspect}, b"x"), AxumDslWpBody::Unreadable));
      }
    RS
    Dir.mktmpdir("web_push_rt") do |dir|
      Dir.mkdir(File.join(dir, "src"))
      File.write(File.join(dir, "Cargo.toml"), <<~TOML)
        [package]
        name = "web_push_rt"
        version = "0.1.0"
        edition = "2021"

        [dependencies]
        serde_json = "1"
        tokio = { version = "1", features = ["rt", "time", "net"] }#{AxumDsl::WebPush.deps(ir)}
      TOML
      File.write(File.join(dir, "src/main.rs"), "#![allow(dead_code)]\n#{AxumDsl::WebPush.items(ir).join("\n")}\n#{main}")
      AxumDsl::Lockfile.pin(dir, AxumDsl::Emit::VETTED_LOCK) # the same crates the emitter names, from the vetted set
      out, err, status = Open3.capture3("cargo", "run", "--quiet", "--locked", chdir: dir)
      assert status.success?, err
      out.lines.map(&:chomp)
    end
  end

  def test_the_sealed_body_opens_and_the_vapid_jwt_verifies
    ua = OpenSSL::PKey::EC.generate("prime256v1")
    vapid = OpenSSL::PKey::EC.generate("prime256v1")
    auth = Random.bytes(16)
    body_b64, jwt, bad_key, unreadable = run_rust(b64u(point(ua)), b64u(auth), b64u(scalar(vapid)))

    body = unb64u(body_b64)
    salt, rs, idlen = body[0, 16], body[16, 4].unpack1("N"), body[20].ord
    as_public = body[21, idlen]
    sealed = body[(21 + idlen)..]
    assert_equal 4096, rs
    assert_equal 65, idlen

    group = ua.group
    secret = ua.dh_compute_key(OpenSSL::PKey::EC::Point.new(group, OpenSSL::BN.new(as_public, 2)))
    ikm = OpenSSL::KDF.hkdf(secret, salt: auth, info: "WebPush: info\0#{point(ua)}#{as_public}".b, length: 32, hash: "SHA256")
    cek = OpenSSL::KDF.hkdf(ikm, salt: salt, info: "Content-Encoding: aes128gcm\0", length: 16, hash: "SHA256")
    nonce = OpenSSL::KDF.hkdf(ikm, salt: salt, info: "Content-Encoding: nonce\0", length: 12, hash: "SHA256")
    cipher = OpenSSL::Cipher.new("aes-128-gcm").decrypt
    cipher.key = cek
    cipher.iv = nonce
    cipher.auth_tag = sealed[-16..]
    cipher.auth_data = ""
    plain = cipher.update(sealed[0...-16]) + cipher.final
    assert_equal "#{PLAINTEXT}\x02".b, plain, "one record: the payload, then the 0x02 delimiter"

    header, claims, signature = jwt.split(".")
    assert_equal({ "typ" => "JWT", "alg" => "ES256" }, JSON.parse(unb64u(header)))
    parsed = JSON.parse(unb64u(claims))
    assert_equal [AUDIENCE, SUBJECT], parsed.values_at("aud", "sub")
    assert_in_delta Time.now.to_i + 12 * 3600, parsed["exp"], 120
    raw = unb64u(signature)
    assert_equal 64, raw.bytesize
    der = OpenSSL::ASN1::Sequence([OpenSSL::ASN1::Integer(OpenSSL::BN.new(raw[0, 32], 2)),
                                   OpenSSL::ASN1::Integer(OpenSSL::BN.new(raw[32, 32], 2))]).to_der
    assert vapid.verify("SHA256", der, "#{header}.#{claims}"), "the ES256 signature verifies with the VAPID public key"

    assert_equal "true", bad_key, "a key that is not a P-256 point is BadKey (the subscription is invalidated)"
    assert_equal "true", unreadable, "a key that is not Base64 is Unreadable (logged, not invalidated)"
  end
end
