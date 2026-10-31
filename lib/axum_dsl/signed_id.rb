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
  # `rails_signed_id(token, purpose: "user/avatar", secret: :secret_key, check_expiry: false)` returns the record
  # id as `Option<i64>`; nil is Rails' `find_signed` finding nothing, and is the fail-closed answer for a bad
  # signature, a wrong purpose, a malformed envelope or a non-integer id. Without `check_expiry:` a non-null `exp`
  # is refused (safe to reject, while ignoring its expiry would not be). `check_expiry: true` is Rails'
  # `verified(token, purpose:)`: no exp or a future one returns the id, an exp now or in the past is nil.
  #
  # `rails_signed_id_for(id, purpose: "user/avatar", secret: :secret_key)` is the other direction: the
  # token Rails' `user.signed_id(purpose: :avatar)` writes, which both this verifier and Rails' verify.
  # `turbo_signed_stream_name(*parts, secret:)` is turbo-rails' `Turbo::StreamsChannel.signed_stream_name`
  # (a MessageVerifier over `generate_key("turbo/signed_stream_verifier_key")`, SHA256, JSON, strict base64,
  # no metadata envelope), `global_id_param(model, id, app:)` is `record.to_gid_param` (the stream-name part
  # a record becomes), and `urlsafe_base64(text)` is `Base64.urlsafe_encode64` (padded).
  # The runtime of each is emitted only when a body (or a view marker) calls it.
  module SignedId
    module_function

    # The builtin flags (Body) that need some of this runtime.
    VERIFY = "rails_signed_id"
    GENERATE = "rails_signed_id_for"
    EXPIRING = "rails_signed_id_for_expiring"
    TURBO = "turbo_signed_stream_name"
    TURBO_VERIFY = "turbo_verify_stream_name"
    GID = "global_id_param"
    SGID = "rails_signed_global_id"
    URLSAFE = "urlsafe_base64"
    VARIATION = "active_storage_variation"
    # The Active Storage disk service's URLs: `blob.url` (DISK_PATH) and the two verifications the routes behind them do.
    DISK_PATH = "active_storage_disk_path"
    VERIFIED_ID = "active_storage_verified_id"
    VERIFIED_KEY = "active_storage_verified_key"
    STORAGE = [DISK_PATH, VERIFIED_ID, VERIFIED_KEY].freeze
    # `inline_disposition(filename)`: the Content-Disposition a disk URL's signed key carries, and the disk route serves.
    INLINE = "inline_disposition"
    BUILTINS = [VERIFY, GENERATE, EXPIRING, TURBO, TURBO_VERIFY, GID, SGID, URLSAFE, VARIATION, *STORAGE, INLINE].freeze

    def used?(ir) = (ir["builtins"].to_a & BUILTINS).any?

    def flag?(ir, *names) = (ir["builtins"].to_a & names).any?

    # The Cargo.toml lines, each led by a newline. The emitter deduplicates them against cookies' lines.
    def deps(ir)
      return "" unless used?(ir)

      lines = ["base64 = \"0.22\""]
      lines.unshift("hmac = \"0.12\"", "sha2 = \"0.10\"", "pbkdf2 = \"0.12\"") if flag?(ir, VERIFY, GENERATE, EXPIRING, TURBO, TURBO_VERIFY, VARIATION, SGID, *STORAGE)
      lines.push("sha1 = \"0.10\"") if flag?(ir, VARIATION, SGID, *STORAGE)
      lines.map { |line| "\n#{line}" }.join
    end

    def items(ir)
      return [] unless used?(ir)

      out = []
      out.concat(verify_items) if flag?(ir, VERIFY)
      out.concat(key_items) if flag?(ir, VERIFY, GENERATE, EXPIRING)
      out.concat(hmac_items) if flag?(ir, GENERATE, EXPIRING, TURBO)
      out.concat(verify_fn) if flag?(ir, VERIFY)
      out.concat(generate_items) if flag?(ir, GENERATE)
      out.concat(iso8601_items) if flag?(ir, VERIFY, EXPIRING, *STORAGE)
      out.concat(expiring_items) if flag?(ir, EXPIRING)
      out.concat(storage_sign_items) if flag?(ir, VARIATION, *STORAGE)
      out.concat(storage_verify_items) if flag?(ir, VERIFIED_ID, VERIFIED_KEY)
      out.concat(disposition_items) if flag?(ir, DISK_PATH, INLINE)
      out.concat(storage_disk_items) if flag?(ir, DISK_PATH)
      out.concat(turbo_key_items) if flag?(ir, TURBO, TURBO_VERIFY)
      out.concat(turbo_items) if flag?(ir, TURBO)
      out.concat(turbo_verify_items) if flag?(ir, TURBO_VERIFY)
      out.concat(gid_items) if flag?(ir, GID)
      out.concat(sgid_items) if flag?(ir, SGID)
      out.concat(urlsafe_items) if flag?(ir, URLSAFE)
      out.concat(variation_items) if flag?(ir, VARIATION)
      out
    end

    # `ActiveStorage::Variation#key`: ActiveStorage.verifier is `Rails.application.message_verifier("ActiveStorage")`
    # (MessageVerifier with digest SHA1, serializer JSON, standard padded base64, over the metadata envelope), so the
    # key of {format: "jpg", resize_to_limit: [1200, 800]} is the base64 of
    # {"_rails":{"data":{"format":"jpg","resize_to_limit":[1200,800]},"pur":"variation"}}, `--` and the HMAC-SHA1 hex,
    # with the secret PBKDF2-HMAC-SHA256(SECRET_KEY_BASE, "ActiveStorage", 1000, 64).
    def variation_items
      <<~'RS'.lines.map(&:chomp)
        fn axum_dsl_active_storage_variation(secret: &[u8], format: &str, width: u32, height: u32) -> String {
            let data = format!(
                "{{\"format\":{},\"resize_to_limit\":[{},{}]}}",
                ::serde_json::to_string(format).unwrap_or_default(),
                width,
                height
            );
            axum_dsl_active_storage_sign(secret, &data, "variation")
        }

        // `blob.signed_id`: ActiveStorage::Blob signs with ActiveStorage.verifier, so its id carries the same SHA1 digest
        // and padded base64 as a variation key (a blob id is the JSON number).
        fn axum_dsl_active_storage_blob_id(secret: &[u8], id: i64) -> String {
            axum_dsl_active_storage_sign(secret, &id.to_string(), "blob_id")
        }

      RS
    end

    # The signer behind every ActiveStorage.verifier message (see variation_items); `expires` is the "exp" the
    # envelope carries between data and pur (ActiveSupport's `expires_at.utc.iso8601(3)`), None for no expiry.
    def storage_sign_items
      <<~'RS'.lines.map(&:chomp)
        fn axum_dsl_active_storage_hmac_key(secret: &[u8]) -> &'static [u8; 64] {
            static KEY: ::std::sync::OnceLock<[u8; 64]> = ::std::sync::OnceLock::new();
            KEY.get_or_init(|| {
                let mut key = [0u8; 64];
                let _ = ::pbkdf2::pbkdf2::<::hmac::Hmac<::sha2::Sha256>>(secret, b"ActiveStorage", 1_000, &mut key);
                key
            })
        }

        fn axum_dsl_active_storage_digest(secret: &[u8], data: &str) -> String {
            use ::hmac::Mac;
            let mut mac = ::hmac::Hmac::<::sha1::Sha1>::new_from_slice(axum_dsl_active_storage_hmac_key(secret)).expect("HMAC takes any key length");
            mac.update(data.as_bytes());
            mac.finalize().into_bytes().iter().map(|byte| format!("{byte:02x}")).collect()
        }

        #[allow(dead_code)]
        fn axum_dsl_active_storage_sign(secret: &[u8], data: &str, purpose: &str) -> String {
            axum_dsl_active_storage_sign_until(secret, data, purpose, None)
        }

        fn axum_dsl_active_storage_sign_until(secret: &[u8], data: &str, purpose: &str, expires: Option<&str>) -> String {
            use ::base64::Engine;
            let exp = expires.map(|at| format!(",\"exp\":\"{at}\"")).unwrap_or_default();
            let json = format!("{{\"_rails\":{{\"data\":{data}{exp},\"pur\":{}}}}}", ::serde_json::to_string(purpose).unwrap_or_default());
            let data = ::base64::engine::general_purpose::STANDARD.encode(json.as_bytes());
            let digest = axum_dsl_active_storage_digest(secret, &data);
            format!("{data}--{digest}")
        }

      RS
    end

    # `ActiveStorage.verifier.verified(message, purpose:)`: the envelope's data, or None for a bad digest, bad base64,
    # a wrong purpose, or an expiry that has passed (an ISO 8601 UTC string with milliseconds compares as text).
    def storage_verify_items
      <<~'RS'.lines.map(&:chomp)
        fn axum_dsl_active_storage_verified(secret: &[u8], token: &str, purpose: &str) -> Option<::serde_json::Value> {
            use ::base64::Engine;
            use ::hmac::Mac;
            let (data, digest) = token.rsplit_once("--")?;
            if digest.len() != 40 || !digest.is_ascii() {
                return None;
            }
            let mut tag = Vec::with_capacity(20);
            for at in (0..40).step_by(2) {
                tag.push(u8::from_str_radix(&digest[at..at + 2], 16).ok()?);
            }
            let mut mac = ::hmac::Hmac::<::sha1::Sha1>::new_from_slice(axum_dsl_active_storage_hmac_key(secret)).ok()?;
            mac.update(data.as_bytes());
            mac.verify_slice(&tag).ok()?;
            let decoded = ::base64::engine::general_purpose::STANDARD
                .decode(data)
                .or_else(|_| ::base64::engine::general_purpose::URL_SAFE.decode(data))
                .ok()?;
            let outer: ::serde_json::Value = ::serde_json::from_slice(&decoded).ok()?;
            let rails = outer.get("_rails")?;
            if rails.get("pur")?.as_str()? != purpose {
                return None;
            }
            if let Some(expires) = rails.get("exp").and_then(|value| value.as_str()) {
                let now = ::std::time::SystemTime::now()
                    .duration_since(::std::time::UNIX_EPOCH)
                    .map_or(0, |elapsed| i64::try_from(elapsed.as_millis()).unwrap_or(0));
                if expires <= axum_dsl_iso8601_ms(now).as_str() {
                    return None;
                }
            }
            rails.get("data").cloned()
        }

        // `ActiveStorage::Blob.find_signed`'s id: the integer inside `blob.signed_id`.
        fn axum_dsl_active_storage_verified_id(secret: &[u8], token: &str) -> Option<i64> {
            axum_dsl_active_storage_verified(secret, token, "blob_id")?.as_i64()
        }

        // The blob key inside a disk service URL's signed key (`purpose: :blob_key`), while it has not expired.
        fn axum_dsl_active_storage_verified_key(secret: &[u8], token: &str) -> Option<String> {
            axum_dsl_active_storage_verified(secret, token, "blob_key")?.get("key")?.as_str().map(str::to_owned)
        }

      RS
    end

    # `blob.url` on the disk service: `/rails/active_storage/disk/<encoded key>/<filename>`, the encoded key being
    # `ActiveStorage.verifier.generate({key:, disposition:, content_type:, service_name:}, expires_in: 5.minutes,
    # purpose: :blob_key)` with `disposition` the inline Content-Disposition of the filename
    # (ActionDispatch::Http::ContentDisposition) and the path segments percent-encoded.
    def storage_disk_items
      <<~'RS'.lines.map(&:chomp)
        fn axum_dsl_path_segment(text: &str) -> String {
            let mut out = String::new();
            for b in text.bytes() {
                if b.is_ascii_alphanumeric() || b"-._~!$&'()*+,;=:@".contains(&b) {
                    out.push(b as char);
                } else {
                    out.push_str(&format!("%{:02X}", b));
                }
            }
            out
        }

        fn axum_dsl_active_storage_disk_path(secret: &[u8], key: &str, filename: &str, content_type: &str) -> String {
            let now = ::std::time::SystemTime::now()
                .duration_since(::std::time::UNIX_EPOCH)
                .map_or(0, |elapsed| i64::try_from(elapsed.as_millis()).unwrap_or(0));
            let json = |text: &str| ::serde_json::to_string(text).unwrap_or_default();
            let data = format!(
                "{{\"key\":{},\"disposition\":{},\"content_type\":{},\"service_name\":\"local\"}}",
                json(key),
                json(&axum_dsl_content_disposition("inline", filename)),
                json(content_type)
            );
            let expires = axum_dsl_iso8601_ms(now.saturating_add(300_000));
            let token = axum_dsl_active_storage_sign_until(secret, &data, "blob_key", Some(&expires));
            format!("/rails/active_storage/disk/{}/{}", axum_dsl_path_segment(&token), axum_dsl_path_segment(filename))
        }

      RS
    end

    # ActionDispatch::Http::ContentDisposition.format(disposition:, filename:): an ASCII `filename=` with anything
    # else `?` or percent-encoded, and the full name percent-encoded in `filename*=UTF-8''`.
    def disposition_items
      <<~'RS'.lines.map(&:chomp)
        fn axum_dsl_content_disposition(disposition: &str, filename: &str) -> String {
            let (mut plain, mut star) = (String::new(), String::new());
            for c in filename.chars() {
                if c.is_ascii_alphanumeric() || " !#$+.^_`|~-".contains(c) {
                    plain.push(c);
                } else if !c.is_ascii() {
                    plain.push('?');
                } else {
                    plain.push_str(&format!("%{:02X}", c as u32));
                }
                let mut buf = [0u8; 4];
                for b in c.encode_utf8(&mut buf).bytes() {
                    if b.is_ascii_alphanumeric() || b"!#$&+.^_`|~-".contains(&b) {
                        star.push(b as char);
                    } else {
                        star.push_str(&format!("%{:02X}", b));
                    }
                }
            }
            format!("{disposition}; filename=\"{plain}\"; filename*=UTF-8''{star}")
        }

      RS
    end

    def verify_items
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

      RS
    end

    def key_items
      <<~'RS'.lines.map(&:chomp)
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

      RS
    end

    def hmac_items
      <<~'RS'.lines.map(&:chomp)
        // The lower-case hex of an HMAC-SHA256 tag: the `--<digest>` tail of every MessageVerifier message.
        fn axum_dsl_hmac_hex(key: &[u8], data: &str) -> String {
            use ::hmac::Mac;
            let mut mac = ::hmac::Hmac::<::sha2::Sha256>::new_from_slice(key).expect("HMAC takes any key length");
            mac.update(data.as_bytes());
            mac.finalize().into_bytes().iter().map(|byte| format!("{byte:02x}")).collect()
        }

      RS
    end

    def verify_fn
      <<~'RS'.lines.map(&:chomp)
        fn axum_dsl_rails_signed_id(secret: &[u8], token: &str, purpose: &str, check_expiry: bool) -> Option<i64> {
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
            // Without check_expiry, an expiring signed id is refused rather than accepted without checking its
            // expiry. With it, this is Rails' `verified(token, purpose:)`: no exp (or a null one) passes, a future
            // exp passes, and an exp now or in the past is nil. Rails writes exp as `iso8601(3)` UTC, a fixed-width
            // string, so comparing the two strings in that format compares the times.
            if let Some(expires) = rails.get("exp").filter(|value| !value.is_null()) {
                if !check_expiry {
                    return None;
                }
                let expires = expires.as_str()?;
                let now = ::std::time::SystemTime::now()
                    .duration_since(::std::time::UNIX_EPOCH)
                    .map_or(0, |elapsed| i64::try_from(elapsed.as_millis()).unwrap_or(0));
                if expires <= axum_dsl_iso8601_ms(now).as_str() {
                    return None;
                }
            }
            if rails.get("pur")?.as_str()? != purpose {
                return None;
            }
            rails.get("data")?.as_i64()
        }

      RS
    end

    # `record.signed_id(purpose:)`: the metadata envelope {"_rails":{"data":id,"pur":purpose}} as JSON,
    # url-safe base64 without padding, `--`, the HMAC-SHA256 hex of that base64 text.
    def generate_items
      <<~'RS'.lines.map(&:chomp)
        fn axum_dsl_rails_signed_id_for(secret: &[u8], id: i64, purpose: &str) -> String {
            use ::base64::Engine;
            let json = format!(
                "{{\"_rails\":{{\"data\":{},\"pur\":{}}}}}",
                id,
                ::serde_json::to_string(purpose).unwrap_or_default()
            );
            let data = ::base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(json.as_bytes());
            let digest = axum_dsl_hmac_hex(axum_dsl_signed_id_key(secret), &data);
            format!("{data}--{digest}")
        }

      RS
    end

    # `record.signed_id(purpose:, expires_in:)`: the same envelope with an "exp" between data and pur, the expiry as
    # ActiveSupport's `expires_at.utc.iso8601(3)` ("2026-10-29T01:02:03.456Z"), taken from the clock at signing.
    def iso8601_items
      <<~'RS'.lines.map(&:chomp)
        fn axum_dsl_iso8601_ms(unix_ms: i64) -> String {
            let secs = unix_ms.div_euclid(1000);
            let ms = unix_ms.rem_euclid(1000);
            let days = secs.div_euclid(86_400);
            let rem = secs.rem_euclid(86_400);
            let z = days + 719_468;
            let era = z.div_euclid(146_097);
            let doe = z.rem_euclid(146_097);
            let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
            let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
            let mp = (5 * doy + 2) / 153;
            let day = doy - (153 * mp + 2) / 5 + 1;
            let month = if mp < 10 { mp + 3 } else { mp - 9 };
            let year = yoe + era * 400 + i64::from(month <= 2);
            format!("{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}.{ms:03}Z", rem / 3600, rem % 3600 / 60, rem % 60)
        }

      RS
    end

    def expiring_items
      <<~'RS'.lines.map(&:chomp)
        fn axum_dsl_rails_signed_id_for_expiring(secret: &[u8], id: i64, purpose: &str, expires_in: i64) -> String {
            use ::base64::Engine;
            let now = ::std::time::SystemTime::now()
                .duration_since(::std::time::UNIX_EPOCH)
                .map_or(0, |elapsed| i64::try_from(elapsed.as_millis()).unwrap_or(0));
            let json = format!(
                "{{\"_rails\":{{\"data\":{},\"exp\":\"{}\",\"pur\":{}}}}}",
                id,
                axum_dsl_iso8601_ms(now.saturating_add(expires_in.saturating_mul(1000))),
                ::serde_json::to_string(purpose).unwrap_or_default()
            );
            let data = ::base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(json.as_bytes());
            let digest = axum_dsl_hmac_hex(axum_dsl_signed_id_key(secret), &data);
            format!("{data}--{digest}")
        }

      RS
    end

    # `Turbo::StreamsChannel.signed_stream_name`: Turbo.signed_stream_verifier is a MessageVerifier over
    # generate_key("turbo/signed_stream_verifier_key"), SHA256, JSON, strict (padded, standard) base64 of the
    # JSON-dumped stream name, with no metadata envelope.
    def turbo_key_items
      <<~'RS'.lines.map(&:chomp)
        fn axum_dsl_turbo_key(secret: &[u8]) -> &'static [u8; 64] {
            static KEY: ::std::sync::OnceLock<[u8; 64]> = ::std::sync::OnceLock::new();
            KEY.get_or_init(|| {
                let mut key = [0u8; 64];
                let _ = ::pbkdf2::pbkdf2::<::hmac::Hmac<::sha2::Sha256>>(
                    secret,
                    b"turbo/signed_stream_verifier_key",
                    1_000,
                    &mut key,
                );
                key
            })
        }

      RS
    end

    def turbo_items
      <<~'RS'.lines.map(&:chomp)
        fn axum_dsl_turbo_signed_stream_name(secret: &[u8], name: &str) -> String {
            use ::base64::Engine;
            let json = ::serde_json::to_string(name).unwrap_or_default();
            let data = ::base64::engine::general_purpose::STANDARD.encode(json.as_bytes());
            let digest = axum_dsl_hmac_hex(axum_dsl_turbo_key(secret), &data);
            format!("{data}--{digest}")
        }

      RS
    end

    # `Turbo.signed_stream_verifier.verified(signed)`: the stream name inside a signed stream name, or None for a
    # bad signature, bad base64 or a value that is not a JSON string (the Action Cable endpoint, Cable).
    def turbo_verify_items
      <<~'RS'.lines.map(&:chomp)
        fn axum_dsl_turbo_verified_stream_name(secret: &[u8], signed: &str) -> Option<String> {
            use ::base64::Engine;
            use ::hmac::Mac;
            let (data, digest) = signed.rsplit_once("--")?;
            if digest.len() != 64 || !digest.is_ascii() {
                return None;
            }
            let mut tag = Vec::with_capacity(32);
            for at in (0..64).step_by(2) {
                tag.push(u8::from_str_radix(&digest[at..at + 2], 16).ok()?);
            }
            let mut mac = ::hmac::Hmac::<::sha2::Sha256>::new_from_slice(axum_dsl_turbo_key(secret)).ok()?;
            mac.update(data.as_bytes());
            mac.verify_slice(&tag).ok()?;
            let decoded = ::base64::engine::general_purpose::STANDARD.decode(data).ok()?;
            ::serde_json::from_slice::<String>(&decoded).ok()
        }

      RS
    end

    # `record.to_gid_param`: "gid://<app>/<Model>/<id>" as url-safe base64 without padding.
    # `record.attachable_sgid`: SignedGlobalID's token over a GID string with `?expires_in` (the query
    # `to_sgid(expires_in: nil)` leaves), purpose `attachable`, the JSON `_rails` envelope, URL-safe
    # **padded** base64, and the SHA1 digest of GlobalID::Verifier. Its key is Rails'
    # `key_generator.generate_key("signed_global_ids")` (PBKDF2-HMAC-SHA256, 1000, 64), once per process.
    def sgid_items
      <<~'RS'.lines.map(&:chomp)
        fn axum_dsl_signed_global_id_key(secret: &[u8]) -> &'static [u8; 64] {
            static KEY: ::std::sync::OnceLock<[u8; 64]> = ::std::sync::OnceLock::new();
            KEY.get_or_init(|| {
                let mut key = [0u8; 64];
                let _ = ::pbkdf2::pbkdf2::<::hmac::Hmac<::sha2::Sha256>>(
                    secret,
                    b"signed_global_ids",
                    1_000,
                    &mut key,
                );
                key
            })
        }

        fn axum_dsl_rails_signed_global_id(secret: &[u8], model: &str, id: i64, app: &str, purpose: &str) -> String {
            use ::base64::Engine;
            use ::hmac::Mac;
            let gid = format!("gid://{app}/{model}/{id}?expires_in");
            let data = ::serde_json::to_string(&gid).unwrap_or_default();
            let json = format!(
                "{{\"_rails\":{{\"data\":{data},\"pur\":{}}}}}",
                ::serde_json::to_string(purpose).unwrap_or_default()
            );
            // GlobalID::Verifier overrides MessageVerifier's encode with the padded URL-safe alphabet.
            let data = ::base64::engine::general_purpose::URL_SAFE.encode(json.as_bytes());
            let key = axum_dsl_signed_global_id_key(secret);
            let mut mac = ::hmac::Hmac::<::sha1::Sha1>::new_from_slice(key).expect("HMAC takes any key length");
            mac.update(data.as_bytes());
            let digest: String = mac.finalize().into_bytes().iter().map(|byte| format!("{byte:02x}")).collect();
            format!("{data}--{digest}")
        }

      RS
    end

    def gid_items
      <<~'RS'.lines.map(&:chomp)
        fn axum_dsl_global_id_param(app: &str, model: &str, id: i64) -> String {
            use ::base64::Engine;
            ::base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(format!("gid://{app}/{model}/{id}").as_bytes())
        }

      RS
    end

    # `Base64.urlsafe_encode64(text)`: the url-safe alphabet, padded with `=`.
    def urlsafe_items
      <<~'RS'.lines.map(&:chomp)
        fn axum_dsl_urlsafe_base64(text: &str) -> String {
            use ::base64::Engine;
            ::base64::engine::general_purpose::URL_SAFE.encode(text.as_bytes())
        }

      RS
    end
  end
end
