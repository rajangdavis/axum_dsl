# frozen_string_literal: true

module AxumDsl
  # Rails' signed IDs (`ActiveRecord::SignedId`): a value a route can carry in a URL, signed with
  # SECRET_KEY_BASE and confined to a purpose. The vocabulary and the exact wire format are Rails 8.2's
  # (`activerecord/lib/active_record/signed_id.rb` and `activesupport/lib/active_support/messages/metadata.rb`):
  # a default app's `signed_id_verifier` is `ActiveRecord.message_verifiers["active_record/signed_id"]`,
  # whose secret is `key_generator.generate_key("active_record/signed_id")` (PBKDF2-HMAC-SHA256, 1000
  # iterations, 64 bytes), and whose generation options are `digest: SHA256, serializer: JSON, url_safe:
  # true` (the active_record railtie's `use_legacy_signed_id_verifier = :generate_and_verify`). A purpose
  # is `"<model>/<purpose>"`: `signed_id(purpose: :avatar)` on User is `"user/avatar"`.
  #
  # `rails_signed_id(token, purpose: "user/avatar", secret: :secret_key)` returns the record id as
  # `Option<i64>`; nil is Rails' `find_signed` finding nothing, and is the fail-closed answer for a bad
  # signature, a wrong purpose, a malformed envelope or a non-integer id. An `exp` in the envelope is
  # refused in this version: an expiring token is safe to reject, while ignoring its expiry would not be.
  # The runtime is emitted only when a body calls it.
  module SignedId
    module_function

    def used?(ir) = ir["builtins"].to_a.include?("rails_signed_id")

    # The Cargo.toml lines, each led by a newline. The emitter deduplicates them against cookies' lines.
    def deps(ir)
      return "" unless used?(ir)

      ["hmac = \"0.12\"", "sha2 = \"0.10\"", "pbkdf2 = \"0.12\"", "base64 = \"0.22\""]
        .map { |line| "\n#{line}" }.join
    end

    def items(ir)
      return [] unless used?(ir)

      <<~'RS'.lines.map(&:chomp)
        // Rails 8 signed IDs: ActiveRecord.message_verifiers["active_record/signed_id"], a
        // MessageVerifier with digest SHA256, serializer JSON and url_safe: true over the
        // {"_rails":{"data":id,"pur":"user/avatar"}} metadata envelope. The secret is
        // PBKDF2-HMAC-SHA256(SECRET_KEY_BASE, "active_record/signed_id", 1000, 64).
        fn axum_dsl_signed_id_hex(text: &str) -> Option<Vec<u8>> {
            if text.len() % 2 != 0 {
                return None;
            }
            let bytes = text.as_bytes();
            let mut out = Vec::with_capacity(bytes.len() / 2);
            for pair in bytes.chunks(2) {
                let high = (pair[0] as char).to_digit(16)?;
                let low = (pair[1] as char).to_digit(16)?;
                out.push((high * 16 + low) as u8);
            }
            Some(out)
        }

        // Rails derives this key once per process from SECRET_KEY_BASE. Avatar is a benchmarked route, so
        // the verifier does too: the OnceLock holds the one secret the service was started with.
        fn axum_dsl_signed_id_key(secret: &[u8]) -> &'static [u8; 64] {
            static KEY: ::std::sync::OnceLock<[u8; 64]> = ::std::sync::OnceLock::new();
            KEY.get_or_init(|| {
                let mut key = [0u8; 64];
                // HMAC accepts any key length, so this cannot fail; the Result is for other PRFs.
                let _ = ::pbkdf2::pbkdf2::<::hmac::Hmac<::sha2::Sha256>>(
                    secret,
                    b"active_record/signed_id",
                    1_000,
                    &mut key,
                );
                key
            })
        }

        fn axum_dsl_rails_signed_id(secret: &[u8], token: &str, purpose: &str) -> Option<i64> {
            use ::base64::Engine;
            use ::hmac::Mac;
            let (data, digest) = token.rsplit_once("--")?;
            if digest.len() != 64 {
                return None;
            }
            let tag = axum_dsl_signed_id_hex(digest)?;
            let key = axum_dsl_signed_id_key(secret);
            let mut mac = ::hmac::Hmac::<::sha2::Sha256>::new_from_slice(key).ok()?;
            mac.update(data.as_bytes());
            mac.verify_slice(&tag).ok()?;
            let decoded = ::base64::engine::general_purpose::URL_SAFE_NO_PAD
                .decode(data)
                .or_else(|_| ::base64::engine::general_purpose::STANDARD_NO_PAD.decode(data))
                .ok()?;
            let text = String::from_utf8(decoded).ok()?;
            let outer: ::serde_json::Value = ::serde_json::from_str(&text).ok()?;
            let rails = outer.get("_rails")?;
            // An expiring signed id is refused rather than accepted without checking its expiry.
            if rails.get("exp").is_some_and(|value| !value.is_null()) {
                return None;
            }
            if rails.get("pur")?.as_str()? != purpose {
                return None;
            }
            rails.get("data")?.as_i64()
        }
      RS
    end
  end
end
