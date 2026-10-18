# frozen_string_literal: true

module AxumDsl
  # Signed and plain cookies (docs/sessions.md). `cookies secret: :secret_key` names the setting every signed
  # cookie is signed with; the Rust that reads, writes and verifies cookies is the compiler's own, emitted only
  # for a file that uses it. What a signed cookie looks like on the wire is a format, and the formats live behind
  # the same narrow calls the database adapters do (db/sqlite.rb): `deps` (the Cargo.toml lines) and `items`
  # (the `sign` and `verify` functions). `:hmac` is the default, `:rails` is Rails' classic MessageVerifier value, and `:rails7` is the JSON serializer and `_rails` metadata envelope a default Rails 7/8 app reads.

  module Cookies
    # The shortest key a cookie may be signed with. A required setting is checked against it as the server starts.
    KEY_MIN = 32

    # `format: :hmac`, the default: `<base64url(value)>.<base64url(HMAC-SHA256(secret, name + "=" + value))>`, no
    # padding. The cookie's name is part of what is signed, so a signed value cannot be moved to another cookie.
    # Verification compares the MAC in constant time (hmac's verify_slice), and a cookie that is not two
    # base64url parts, or whose MAC does not match, reads as absent.
    module Hmac
      module_function

      def deps = ["hmac = \"0.12\"", "sha2 = \"0.10\"", "base64 = \"0.22\""]

      # sign(secret, name, value) -> String, when `set`; verify(secret, name, signed) -> Option<String>, when `read`.
      def items(read:, set:)
        out = [
          "fn axum_dsl_cookie_mac(secret: &[u8], name: &str, value: &str) -> Option<::hmac::Hmac<::sha2::Sha256>> {",
          "    use ::hmac::Mac;",
          "    let mut mac = ::hmac::Hmac::<::sha2::Sha256>::new_from_slice(secret).ok()?;",
          "    mac.update(name.as_bytes());",
          "    mac.update(b\"=\");",
          "    mac.update(value.as_bytes());",
          "    Some(mac)",
          "}",
          ""
        ]
        if set
          out.concat([
            "fn axum_dsl_cookie_sign(secret: &[u8], name: &str, value: &str) -> String {",
            "    use ::base64::Engine;",
            "    use ::hmac::Mac;",
            "    let url = ::base64::engine::general_purpose::URL_SAFE_NO_PAD;",
            "    let tag = match axum_dsl_cookie_mac(secret, name, value) {",
            "        Some(mac) => mac.finalize().into_bytes(),",
            "        None => return String::new(),",
            "    };",
            "    format!(\"{}.{}\", url.encode(value), url.encode(tag))",
            "}",
            ""
          ])
        end
        if read
          out.concat([
            "fn axum_dsl_cookie_verify(secret: &[u8], name: &str, signed: &str) -> Option<String> {",
            "    use ::base64::Engine;",
            "    use ::hmac::Mac;",
            "    let url = ::base64::engine::general_purpose::URL_SAFE_NO_PAD;",
            "    let (value_part, tag_part) = signed.split_once('.')?;",
            "    let value = String::from_utf8(url.decode(value_part).ok()?).ok()?;",
            "    let tag = url.decode(tag_part).ok()?;",
            "    axum_dsl_cookie_mac(secret, name, &value)?.verify_slice(&tag).ok()?;",
            "    Some(value)",
            "}",
            ""
          ])
        end
        out
      end
    end

    # `format: :rails`: Rails' `ActiveSupport::MessageVerifier` value, with the Marshal serializer. Rails 8.0's
    # activesupport/lib/active_support/message_verifier.rb: `encode` is `Base64.strict_encode64`, `SEPARATOR` is
    # `"--"`, and `generate_digest` is `OpenSSL::HMAC.hexdigest(digest, secret, data)` (lower-case hex, not a
    # Base64 tag). So a cookie is `Base64.strict_encode64(Marshal.dump(value))--HMAC-SHA1-hex`, and verification
    # recomputes the HMAC over everything before the last `--` and compares the digest bytes in constant time.
    # The key is the signed cookie jar's `ActiveSupport::KeyGenerator#generate_key(signed_cookie_salt, 64)`
    # (actionpack/lib/action_dispatch/middleware/cookies.rb). Rails' application builds that generator with
    # `KeyGenerator.new(secret_key_base, iterations: 1000)` (railties/lib/rails/application.rb, `key_generator`),
    # and PBKDF2-HMAC-SHA1 is KeyGenerator's digest class default (activesupport/key_generator.rb); the salt is
    # the `"signed cookie"` default that actionpack/lib/action_dispatch/railtie.rb gives
    # `config.action_dispatch.signed_cookie_salt`. MessageVerifier's default serializer is Marshal, which is the
    # cookie jar's serializer when `config.action_dispatch.cookies_serializer = :marshal`; Rails 4.1 and later
    # default that to :json, and Rails 6 and later wrap purpose/expiry metadata around it, so this format reads
    # the Marshal form only (docs/sessions.md says so).
    module RailsMessageVerifier
      module_function

      def deps = ["hmac = \"0.12\"", "sha1 = \"0.10\"", "pbkdf2 = \"0.12\"", "base64 = \"0.22\""]

      def items(read:, set:)
        out = [
          "// Rails' signed cookie (format: :rails): ActiveSupport::MessageVerifier with the Marshal serializer.",
          "// data = Base64.strict_encode64(Marshal.dump(value)); digest = OpenSSL::HMAC.hexdigest(\"SHA1\", key, data);",
          "// the cookie is data + \"--\" + digest, lower-case hex, as Rails 8.0's message_verifier.rb writes it.",
          "// key = generate_key(\"signed cookie\", 64): PBKDF2-HMAC-SHA1, 1000 iterations (Rails.application.key_generator).",
          "fn axum_dsl_cookie_rails_key() -> &'static [u8] {",
          "    static KEY: ::std::sync::OnceLock<[u8; 64]> = ::std::sync::OnceLock::new();",
          "    KEY.get_or_init(|| {",
          "        let mut key = [0u8; 64];",
          "        // HMAC accepts any key length, so this cannot fail; the Result is for other PRFs.",
          "        let _ = ::pbkdf2::pbkdf2::<::hmac::Hmac<::sha1::Sha1>>(axum_dsl_cookie_key(), b\"signed cookie\", 1_000, &mut key);",
          "        key",
          "    })",
          "}",
          ""
        ]
        if set
          out.concat([
            "fn axum_dsl_cookie_rails_digest(data: &str) -> String {",
            "    use ::hmac::Mac;",
            "    let mut mac = ::hmac::Hmac::<::sha1::Sha1>::new_from_slice(axum_dsl_cookie_rails_key())",
            "        .expect(\"HMAC accepts any key length\");",
            "    mac.update(data.as_bytes());",
            "    mac.finalize().into_bytes().iter().map(|byte| format!(\"{:02x}\", *byte)).collect()",
            "}",
            "",
            "fn axum_dsl_cookie_rails_long(out: &mut Vec<u8>, value: usize) {",
            "    if value == 0 {",
            "        out.push(0);",
            "        return;",
            "    }",
            "    if value < 123 {",
            "        out.push((value + 5) as u8);",
            "        return;",
            "    }",
            "    let mut bytes = Vec::new();",
            "    let mut rest = value;",
            "    while rest > 0 {",
            "        bytes.push((rest & 0xff) as u8);",
            "        rest >>= 8;",
            "    }",
            "    out.push(bytes.len() as u8);",
            "    out.extend_from_slice(&bytes);",
            "}",
            "",
            "// Marshal.dump of a UTF-8 String: \\x04\\x08I\"<length><bytes>\\x06:\\x06ET.",
            "fn axum_dsl_cookie_rails_marshal(value: &str) -> Vec<u8> {",
            "    let bytes = value.as_bytes();",
            "    let mut out = vec![4u8, 8u8, b'I', b'\"'];",
            "    axum_dsl_cookie_rails_long(&mut out, bytes.len());",
            "    out.extend_from_slice(bytes);",
            "    out.extend_from_slice(&[6u8, b':', 6u8, b'E', b'T']);",
            "    out",
            "}",
            "",
            "fn axum_dsl_cookie_sign_rails(_name: &str, value: &str) -> String {",
            "    use ::base64::Engine;",
            "    let data = ::base64::engine::general_purpose::STANDARD.encode(axum_dsl_cookie_rails_marshal(value));",
            "    format!(\"{data}--{}\", axum_dsl_cookie_rails_digest(&data))",
            "}",
            ""
          ])
        end
        if read
          out.concat([
            "fn axum_dsl_cookie_rails_read_long(bytes: &[u8], at: usize) -> Option<(usize, usize)> {",
            "    let first = *bytes.get(at)? as usize;",
            "    if first == 0 {",
            "        return Some((0, at + 1));",
            "    }",
            "    if first > 4 && first < 128 {",
            "        return Some((first - 5, at + 1));",
            "    }",
            "    if first > ::std::mem::size_of::<usize>() {",
            "        return None;",
            "    }",
            "    let mut value = 0usize;",
            "    for index in 0..first {",
            "        value |= (*bytes.get(at + 1 + index)? as usize) << (8 * index);",
            "    }",
            "    Some((value, at + 1 + first))",
            "}",
            "",
            "fn axum_dsl_cookie_rails_unmarshal(bytes: &[u8]) -> Option<String> {",
            "    if bytes.get(..4)? != &[4u8, 8u8, b'I', b'\"'][..] {",
            "        return None;",
            "    }",
            "    let (length, start) = axum_dsl_cookie_rails_read_long(bytes, 4)?;",
            "    let end = start.checked_add(length)?;",
            "    if bytes.len() != end.checked_add(5)? {",
            "        return None;",
            "    }",
            "    if bytes.get(end..)? != &[6u8, b':', 6u8, b'E', b'T'][..] {",
            "        return None;",
            "    }",
            "    String::from_utf8(bytes.get(start..end)?.to_vec()).ok()",
            "}",
            "",
            "fn axum_dsl_cookie_rails_hex(text: &str) -> Option<Vec<u8>> {",
            "    if text.len() % 2 != 0 {",
            "        return None;",
            "    }",
            "    let bytes = text.as_bytes();",
            "    let mut out = Vec::with_capacity(bytes.len() / 2);",
            "    for pair in bytes.chunks(2) {",
            "        let high = (pair[0] as char).to_digit(16)?;",
            "        let low = (pair[1] as char).to_digit(16)?;",
            "        out.push((high * 16 + low) as u8);",
            "    }",
            "    Some(out)",
            "}",
            "",
            "fn axum_dsl_cookie_verify_rails(_name: &str, signed: &str) -> Option<String> {",
            "    use ::base64::Engine;",
            "    use ::hmac::Mac;",
            "    let (data, digest) = signed.rsplit_once(\"--\")?;",
            "    if digest.len() != 40 {",
            "        return None;",
            "    }",
            "    let tag = axum_dsl_cookie_rails_hex(digest)?;",
            "    let mut mac = ::hmac::Hmac::<::sha1::Sha1>::new_from_slice(axum_dsl_cookie_rails_key()).ok()?;",
            "    mac.update(data.as_bytes());",
            "    mac.verify_slice(&tag).ok()?;",
            "    let dumped = ::base64::engine::general_purpose::STANDARD.decode(data).ok()?;",
            "    axum_dsl_cookie_rails_unmarshal(&dumped)",
            "}",
            ""
          ])
        end
        out
      end
    end

    # `format: :rails7`: the signed cookie a default Rails 7.0+ (and 8.x) application writes. The cookie jar
    # serializes the value with `:json` (config.action_dispatch.cookies_serializer = :json, the
    # `load_defaults "7.0"` default: railties/lib/rails/application/configuration.rb), and with
    # `use_cookies_with_metadata = true` (the `load_defaults "6.0"` default) signs
    # `{"_rails":{"message":<Base64 of the JSON text>,"exp":null,"pur":"cookie.<name>"}}`
    # (activesupport/lib/active_support/messages/metadata.rb, the legacy envelope: the cookie verifier's
    # serializer is ActiveSupport::MessageEncryptor::NullSerializer, which is not in ENVELOPE_SERIALIZERS,
    # so even Rails 7.1+'s use_message_serializer_for_metadata keeps this shape, see
    # actionpack/lib/action_dispatch/middleware/cookies.rb). MessageVerifier then Base64.strict_encodes the
    # envelope, appends "--" and the lower-case hex of OpenSSL::HMAC.hexdigest("SHA1", key, data)
    # (activesupport/lib/active_support/message_verifier.rb: SEPARATOR, encode and generate_digest). The
    # verifier's digest is the signed jar's signed_cookie_digest, `request.signed_cookie_digest || "SHA1"`,
    # and actionpack's railtie leaves config.action_dispatch.signed_cookie_digest unset, so the digest is
    # still SHA1 in Rails 8. What Rails 7.0's defaults change is the key derivation: the jar calls
    # `key_generator.generate_key("signed cookie")` with key size 64, and
    # Rails.application.key_generator is KeyGenerator.new(secret_key_base, iterations: 1000), whose digest
    # class is config.active_support.key_generator_hash_digest_class, OpenSSL::Digest::SHA256 under
    # `load_defaults "7.0"` (railties/lib/rails/application.rb, activesupport/key_generator.rb,
    # railties/lib/rails/application/configuration.rb; the salt default is actionpack's
    # config.action_dispatch.signed_cookie_salt = "signed cookie"). So the key is
    # PBKDF2-HMAC-SHA256(SECRET_KEY_BASE, "signed cookie", 1000, 64 bytes). The value must be a JSON
    # String: Rails' JSON serializer writes other types too, but `cookie(:name)` is a `:string?`, so a
    # number, array or object reads as absent. `permanent: true`/`max_age:` write the signed metadata's `exp`
    # as a UTC ISO8601 string with three fractional digits (`Messages::Metadata.pick_expiry` calls
    # `expires_at.utc.iso8601(3)`, e.g. `"3018-07-11T16:11:26.753Z"`), not Unix seconds. Rails'
    # `cookie_metadata` derives it only from `:expires`; a Rails `max_age` alone writes `exp: null`. Our
    # `max_age:` writes the string too: it is the same instant as the HTTP `Max-Age`, tighter than null, and
    # valid to Rails. A null exp is Rails' non-expiring form and is still read; a non-null exp must be a
    # string strictly after now, or the cookie reads as absent, as `Messages::Metadata#verify` has it
    # (`parse_expiry` + `Time.iso8601`); an integer or float exp is refused (the Rails comparison would
    # raise), and the signature is checked first.
    module RailsJson
      module_function

      def deps = ["hmac = \"0.12\"", "sha1 = \"0.10\"", "sha2 = \"0.10\"", "pbkdf2 = \"0.12\"", "base64 = \"0.22\""]

      def items(read:, set:)
        out = [
          '// Rails 7/8 signed cookie (format: :rails7): ActiveSupport::MessageVerifier with the JSON cookie',
          '// serializer and the _rails metadata envelope (actionpack action_dispatch/middleware/cookies.rb).',
          '// value -> ActiveSupport::JSON.encode(value) -> Base64 -> {"_rails":{"message":...,"exp":<null',
          '// or an ISO8601 string>,"pur":"cookie.NAME"}} -> Base64 -> "--" -> HMAC-SHA1 hex (metadata.rb).',
          '// key = key_generator.generate_key("signed cookie") = PBKDF2-HMAC-SHA256(SECRET_KEY_BASE,',
          '// "signed cookie", 1000, 64), the load_defaults 7.0 default (railties/application/configuration.rb).',
          "fn axum_dsl_cookie_rails7_key() -> &'static [u8] {",
          '    static KEY: ::std::sync::OnceLock<[u8; 64]> = ::std::sync::OnceLock::new();',
          '    KEY.get_or_init(|| {',
          '        let mut key = [0u8; 64];',
          '        // HMAC accepts any key length, so this cannot fail; the Result is for other PRFs.',
          '        let _ = ::pbkdf2::pbkdf2::<::hmac::Hmac<::sha2::Sha256>>(axum_dsl_cookie_key(), b"signed cookie", 1_000, &mut key);',
          '        key',
          '    })',
          '}',
          '',
        ]
        if set
          out.concat([
            '// Rails writes the signed exp as a UTC ISO8601 string (Messages::Metadata.pick_expiry:',
            '// expires_at.utc.iso8601(3)), so a permanent or max_age cookie formats now + its Max-Age; the',
            '// civil-from-days conversion below is the Howard Hinnant algorithm, std only, no crate.',
            'fn axum_dsl_cookie_rails7_now() -> i64 {',
            '    ::std::time::SystemTime::now()',
            '        .duration_since(::std::time::UNIX_EPOCH)',
            '        .map(|elapsed| elapsed.as_secs() as i64)',
            '        .unwrap_or(0)',
            '}',
            '',
            'fn axum_dsl_cookie_rails7_civil_from_days(days: i64) -> (i64, i64, i64) {',
            '    let z = days + 719_468;',
            '    let era = (if z >= 0 { z } else { z - 146_096 }) / 146_097;',
            '    let doe = z - era * 146_097;',
            '    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;',
            '    let y = yoe + era * 400;',
            '    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);',
            '    let mp = (5 * doy + 2) / 153;',
            '    let day = doy - (153 * mp + 2) / 5 + 1;',
            '    let month = if mp < 10 { mp + 3 } else { mp - 9 };',
            '    (if month <= 2 { y + 1 } else { y }, month, day)',
            '}',
            '',
            'fn axum_dsl_cookie_rails7_iso8601(seconds: i64) -> String {',
            '    let days = seconds.div_euclid(86_400);',
            '    let rest = seconds.rem_euclid(86_400);',
            '    let (year, month, day) = axum_dsl_cookie_rails7_civil_from_days(days);',
            '    format!(',
            '        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.000Z",',
            '        year,',
            '        month,',
            '        day,',
            '        rest / 3_600,',
            '        (rest % 3_600) / 60,',
            '        rest % 60',
            '    )',
            '}',
            '',
            '// ActiveSupport::JSON.encode of a String, body only: JSON escapes, then Rails extra escaping of',
            '// <, > and & (and U+2028/U+2029) as encoding.rb does; UTF-8 passes through unchanged.',
            'fn axum_dsl_cookie_rails7_json_body(out: &mut String, value: &str) {',
            '    for ch in value.chars() {',
            '        match u32::from(ch) {',
            '            0x22 => out.push_str(r#"\""#),',
            '            0x5c => { out.push_str(r#"\"#); out.push_str(r#"\"#); }',
            '            0x0a => out.push_str(r#"\n"#),',
            '            0x0d => out.push_str(r#"\r"#),',
            '            0x09 => out.push_str(r#"\t"#),',
            '            0x08 => out.push_str(r#"\b"#),',
            '            0x0c => out.push_str(r#"\f"#),',
            '            0x3c => out.push_str(r#"\u003c"#),',
            '            0x3e => out.push_str(r#"\u003e"#),',
            '            0x26 => out.push_str(r#"\u0026"#),',
            '            0x2028 => out.push_str(r#"\u2028"#),',
            '            0x2029 => out.push_str(r#"\u2029"#),',
            '            0x00..=0x1f => out.push_str(&format!("{}{:04x}", r#"\u"#, u32::from(ch))),',
            '            _ => out.push(ch),',
            '        }',
            '    }',
            '}',
            '',
            'fn axum_dsl_cookie_rails7_digest(data: &str) -> String {',
            '    use ::hmac::Mac;',
            '    let mut mac = ::hmac::Hmac::<::sha1::Sha1>::new_from_slice(axum_dsl_cookie_rails7_key())',
            '        .expect("HMAC accepts any key length");',
            '    mac.update(data.as_bytes());',
            '    mac.finalize().into_bytes().iter().map(|byte| format!("{:02x}", *byte)).collect()',
            '}',
            '',
            'fn axum_dsl_cookie_sign_rails7(name: &str, value: &str, max_age: Option<i64>) -> String {',
            '    use ::base64::Engine;',
            '    let std = ::base64::engine::general_purpose::STANDARD;',
            '    let mut payload = String::from("\"");',
            '    axum_dsl_cookie_rails7_json_body(&mut payload, value);',
            '    payload.push_str("\"");',
            '    let message = std.encode(payload.as_bytes());',
            '    let mut purpose = String::from("cookie.");',
            '    axum_dsl_cookie_rails7_json_body(&mut purpose, name);',
            '    // A positive lifetime becomes the signed metadata exp as Rails writes it: a quoted UTC',
            '    // ISO8601 string with three fractional digits. 0 and negative are the HTTP Max-Age alone, so',
            '    // Rails\'s non-expiring `exp: null` is written. saturating_add keeps it panic-free.',
            '    let exp = match max_age {',
            '        Some(seconds) if seconds > 0 => {',
            '            let expires = axum_dsl_cookie_rails7_now().saturating_add(seconds);',
            '            format!("\"{}\"", axum_dsl_cookie_rails7_iso8601(expires))',
            '        }',
            '        _ => String::from("null"),',
            '    };',
            '    let envelope = format!("{{\"_rails\":{{\"message\":\"{message}\",\"exp\":{exp},\"pur\":\"{purpose}\"}}}}");',
            '    let data = std.encode(envelope.as_bytes());',
            '    format!("{data}--{}", axum_dsl_cookie_rails7_digest(&data))',
            '}',
            ''
          ])
        end
        if read
          out.concat([
            'fn axum_dsl_cookie_rails7_now_ms() -> i64 {',
            '    ::std::time::SystemTime::now()',
            '        .duration_since(::std::time::UNIX_EPOCH)',
            '        .map(|elapsed| elapsed.as_millis() as i64)',
            '        .unwrap_or(0)',
            '}',
            '',
            'fn axum_dsl_cookie_rails7_hex(text: &str) -> Option<Vec<u8>> {',
            '    if text.len() % 2 != 0 {',
            '        return None;',
            '    }',
            '    let bytes = text.as_bytes();',
            '    let mut out = Vec::with_capacity(bytes.len() / 2);',
            '    for pair in bytes.chunks(2) {',
            '        let high = (pair[0] as char).to_digit(16)?;',
            '        let low = (pair[1] as char).to_digit(16)?;',
            '        out.push((high * 16 + low) as u8);',
            '    }',
            '    Some(out)',
            '}',
            '',
            'fn axum_dsl_cookie_rails7_number(bytes: &[u8], at: usize, len: usize) -> Option<i64> {',
            '    let mut value = 0i64;',
            '    for index in 0..len {',
            '        let byte = *bytes.get(at + index)?;',
            '        if !(48..=57).contains(&byte) {',
            '            return None;',
            '        }',
            '        value = value.checked_mul(10)?.checked_add((byte - 48) as i64)?;',
            '    }',
            '    Some(value)',
            '}',
            '',
            'fn axum_dsl_cookie_rails7_days_in_month(year: i64, month: i64) -> i64 {',
            '    match month {',
            '        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,',
            '        4 | 6 | 9 | 11 => 30,',
            '        2 if (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 => 29,',
            '        2 => 28,',
            '        _ => 0,',
            '    }',
            '}',
            '',
            'fn axum_dsl_cookie_rails7_days_from_civil(year: i64, month: i64, day: i64) -> i64 {',
            '    let y = if month <= 2 { year - 1 } else { year };',
            '    let era = (if y >= 0 { y } else { y - 399 }) / 400;',
            '    let yoe = y - era * 400;',
            '    let mp = if month > 2 { month - 3 } else { month + 9 };',
            '    let doy = (153 * mp + 2) / 5 + day - 1;',
            '    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;',
            '    era * 146_097 + doe - 719_468',
            '}',
            '',
            '// Messages::Metadata.parse_expiry + Time.iso8601: a non-String is refused (Rails raises), and a',
            '// String is YYYY-MM-DDTHH:MM:SSZ or with 1-9 fractional digits, of which the first three are',
            '// milliseconds. Invalid fields and malformed lengths are refused; the MAC is checked first.',
            'fn axum_dsl_cookie_rails7_exp_ms(text: &str) -> Option<i64> {',
            '    let bytes = text.as_bytes();',
            '    if bytes.len() < 20',
            '        || bytes.get(4) != Some(&b\'-\')',
            '        || bytes.get(7) != Some(&b\'-\')',
            '        || bytes.get(10) != Some(&b\'T\')',
            '        || bytes.get(13) != Some(&b\':\')',
            '        || bytes.get(16) != Some(&b\':\')',
            '        || bytes.last() != Some(&b\'Z\')',
            '    {',
            '        return None;',
            '    }',
            '    let millis = if bytes.len() == 20 {',
            '        0',
            '    } else {',
            '        if bytes.get(19) != Some(&b\'.\') {',
            '            return None;',
            '        }',
            '        let digits = bytes.get(20..bytes.len() - 1)?;',
            '        if digits.is_empty() || digits.len() > 9 {',
            '            return None;',
            '        }',
            '        let mut millis = 0i64;',
            '        for index in 0..3 {',
            '            let byte = *digits.get(index).unwrap_or(&b\'0\');',
            '            if !(48..=57).contains(&byte) {',
            '                return None;',
            '            }',
            '            millis = millis * 10 + (byte - 48) as i64;',
            '        }',
            '        for byte in digits {',
            '            if !(48..=57).contains(byte) {',
            '                return None;',
            '            }',
            '        }',
            '        millis',
            '    };',
            '    let year = axum_dsl_cookie_rails7_number(bytes, 0, 4)?;',
            '    let month = axum_dsl_cookie_rails7_number(bytes, 5, 2)?;',
            '    let day = axum_dsl_cookie_rails7_number(bytes, 8, 2)?;',
            '    let hour = axum_dsl_cookie_rails7_number(bytes, 11, 2)?;',
            '    let minute = axum_dsl_cookie_rails7_number(bytes, 14, 2)?;',
            '    let second = axum_dsl_cookie_rails7_number(bytes, 17, 2)?;',
            '    if !(1..=12).contains(&month)',
            '        || day < 1',
            '        || day > axum_dsl_cookie_rails7_days_in_month(year, month)',
            '        || hour > 23',
            '        || minute > 59',
            '        || second > 59',
            '    {',
            '        return None;',
            '    }',
            '    let days = axum_dsl_cookie_rails7_days_from_civil(year, month, day);',
            '    let seconds = days',
            '        .checked_mul(86_400)?',
            '        .checked_add(hour * 3_600 + minute * 60 + second)?;',
            '    seconds.checked_mul(1_000)?.checked_add(millis)',
            '}',
            '',
            'fn axum_dsl_cookie_verify_rails7(name: &str, signed: &str) -> Option<String> {',
            '    use ::base64::Engine;',
            '    use ::hmac::Mac;',
            '    let (data, digest) = signed.rsplit_once("--")?;',
            '    if digest.len() != 40 {',
            '        return None;',
            '    }',
            '    let tag = axum_dsl_cookie_rails7_hex(digest)?;',
            '    let mut mac = ::hmac::Hmac::<::sha1::Sha1>::new_from_slice(axum_dsl_cookie_rails7_key()).ok()?;',
            '    mac.update(data.as_bytes());',
            '    mac.verify_slice(&tag).ok()?;',
            '    let decoded = ::base64::engine::general_purpose::STANDARD.decode(data).ok()?;',
            '    let text = String::from_utf8(decoded).ok()?;',
            '    let outer: ::serde_json::Value = ::serde_json::from_str(&text).ok()?;',
            '    let payload = match outer.get("_rails") {',
            '        Some(rails) => {',
            '            // use_cookies_with_metadata: the envelope carries the purpose and, when the writer set a',
            '            // lifetime, a quoted UTC ISO8601 exp (`iso8601(3)`). Null is the non-expiring form; a non-null',
            '            // exp must be a string, and strictly after now, as Messages::Metadata#verify does.',
            '            let purpose = format!("cookie.{}", name);',
            '            if rails.get("pur")?.as_str()? != purpose.as_str() {',
            '                return None;',
            '            }',
            '            if let Some(exp) = rails.get("exp") {',
            '                if !exp.is_null() {',
            '                    // A string, never an integer: parse_expiry leaves a non-String unchanged and the',
            '                    // Rails comparison then raises, so fail closed here too.',
            '                    let exp = exp.as_str()?;',
            '                    if axum_dsl_cookie_rails7_exp_ms(exp)? <= axum_dsl_cookie_rails7_now_ms() {',
            '                        return None;',
            '                    }',
            '                }',
            '            }',
            '            let message = rails.get("message")?.as_str()?;',
            '            let decoded = ::base64::engine::general_purpose::STANDARD.decode(message).ok()?;',
            '            String::from_utf8(decoded).ok()?',
            '        }',
            '        // use_cookies_with_metadata = false writes the JSON text directly (no envelope).',
            '        None => text,',
            '    };',
            '    ::serde_json::from_str::<String>(&payload).ok()',
            '}',
            ''
          ])
        end
        out
      end
    end

    # The format a `cookies` declaration names => the module that emits for it. The hmac format keeps the
    # runtime names it has always had, so a service that does not use format: emits byte-identical code.
    FORMATS = { "hmac" => Hmac, "rails" => RailsMessageVerifier, "rails7" => RailsJson }.freeze


    module_function

    def backend(format) = FORMATS.fetch(format)

    # The signed format a read or a write uses. The arrays are written by Body from each cookie call; the
    # fallback covers an IR made before a call recorded a format.
    def read_formats(decl) = decl["read_formats"] || (decl["read"] ? [decl["format"]] : [])
    def set_formats(decl) = decl["set_formats"] || (decl["set"] ? [decl["format"]] : [])

    # Whether any body reads or writes a signed value (delete_cookie and an unsigned cookie sign nothing).
    def signs?(decl) = !read_formats(decl).empty? || !set_formats(decl).empty?

    # The runtime name of a format's read/write wrapper: hmac keeps `axum_dsl_cookie`/`axum_dsl_set_cookie`,
    # every other format gets a suffix.
    def read_fn(format) = format == "hmac" ? "axum_dsl_cookie" : "axum_dsl_cookie_#{format}"
    def set_fn(format) = format == "hmac" ? "axum_dsl_set_cookie" : "axum_dsl_set_cookie_#{format}"

    # The Cargo.toml dependency lines the cookies need, each led by a newline.
    def deps(ir)
      decl = ir["cookies"]
      return "" unless decl && signs?(decl)

      (read_formats(decl) + set_formats(decl)).uniq.flat_map { |format| backend(format).deps }.uniq.map { |line| "\n#{line}" }.join
    end

    # The statements at the top of main that refuse a key that is too short, like a setting that cannot load: a
    # message and exit status 2 before anything listens. They run after the settings are loaded.
    def start_lines(ir)
      decl = ir["cookies"]
      return [] unless decl

      ["    if settings().#{decl['secret']}.len() < #{KEY_MIN} {",
       "        eprintln!(#{AxumDsl.rstr("error: #{decl['env']} is the key cookies are signed with, and it must be at least #{KEY_MIN} bytes")});",
       "        std::process::exit(2);",
       "    }"]
    end

    # Rack escapes a cookie's value with URI.encode_www_form_component and decodes it when reading; Rails'
    # signed cookies come back percent-encoded, and a plain cookie is written the same way.
    def quote_lines
      ["fn axum_dsl_cookie_quote(value: &str) -> String {",
       "    let mut out = String::new();",
       "    for byte in value.bytes() {",
       "        match byte {",
       "            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'*' | b'-' | b'.' | b'_' => out.push(byte as char),",
       "            b' ' => out.push('+'),",
       "            _ => out.push_str(&format!(\"%{byte:02X}\")),",
       "        }",
       "    }",
       "    out",
       "}",
       ""]
    end

    def unquote_lines
      ["fn axum_dsl_cookie_unquote(value: &str) -> String {",
       "    let bytes = value.as_bytes();",
       "    let mut out = Vec::with_capacity(bytes.len());",
       "    let mut index = 0;",
       "    while index < bytes.len() {",
       "        match bytes[index] {",
       "            b'+' => {",
       "                out.push(b' ');",
       "                index += 1;",
       "            }",
       "            b'%' if index + 2 < bytes.len() => {",
       "                let high = (bytes[index + 1] as char).to_digit(16);",
       "                let low = (bytes[index + 2] as char).to_digit(16);",
       "                if let (Some(high), Some(low)) = (high, low) {",
       "                    out.push((high * 16 + low) as u8);",
       "                    index += 3;",
       "                } else {",
       "                    out.push(bytes[index]);",
       "                    index += 1;",
       "                }",
       "            }",
       "            byte => {",
       "                out.push(byte);",
       "                index += 1;",
       "            }",
       "        }",
       "    }",
       "    String::from_utf8_lossy(&out).into_owned()",
       "}",
       ""]
    end

    # The body of a Set-Cookie line after the name=value pair: the attributes every cookie shares.
    def cookie_attribute_lines(value_expr)
      ["    let mut line = format!(\"{}={}; Path=/\", name, #{value_expr});",
       "    if let Some(seconds) = max_age {",
       "        line.push_str(&format!(\"; Max-Age={seconds}\"));",
       "    }",
       "    line.push_str(&format!(\"; SameSite={same_site}\"));",
       "    if http_only {",
       "        line.push_str(\"; HttpOnly\");",
       "    }",
       "    if secure {",
       "        line.push_str(\"; Secure\");",
       "    }",
       "    line"]
    end

    # The Cookie reader for one signed format: hmac verifies the raw value, rails decodes Rack's escaping
    # before it verifies.
    def read_lines(format)
      verify = if format == "hmac"
                 "axum_dsl_cookie_verify(axum_dsl_cookie_key(), name, signed)"
               else
                 "axum_dsl_cookie_verify_#{format}(name, &axum_dsl_cookie_unquote(signed))"
               end
      ["fn #{read_fn(format)}(headers: &::axum::http::HeaderMap, name: &str) -> Option<String> {",
       "    for line in headers.get_all(::axum::http::header::COOKIE) {",
       "        let Ok(line) = line.to_str() else { continue };",
       "        for pair in line.split(';') {",
       "            if let Some((key, signed)) = pair.trim().split_once('=') {",
       "                if key == name {",
       "                    if let Some(value) = #{verify} {",
       "                        return Some(value);",
       "                    }",
       "                }",
       "            }",
       "        }",
       "    }",
       "    None",
       "}",
       ""]
    end

    # The Set-Cookie writer for one signed format: rails percent-encodes the whole signed value as Rack does.
    # rails7 also takes max_age: it becomes the signed metadata exp, separate from the HTTP Max-Age.
    def set_lines(format)
      value = if format == "hmac"
                "axum_dsl_cookie_sign(axum_dsl_cookie_key(), name, value)"
              elsif format == "rails7"
                "axum_dsl_cookie_quote(&axum_dsl_cookie_sign_rails7(name, value, max_age))"
              else
                "axum_dsl_cookie_quote(&axum_dsl_cookie_sign_#{format}(name, value))"
              end
      ["fn #{set_fn(format)}(name: &str, value: &str, http_only: bool, same_site: &str, secure: bool, max_age: Option<i64>) -> String {",
       *cookie_attribute_lines(value),
       "}",
       ""]
    end

    # A plain cookie: the value with no signature, still percent-encoded as Rack writes it.
    def raw_read_lines
      ["fn axum_dsl_cookie_raw(headers: &::axum::http::HeaderMap, name: &str) -> Option<String> {",
       "    for line in headers.get_all(::axum::http::header::COOKIE) {",
       "        let Ok(line) = line.to_str() else { continue };",
       "        for pair in line.split(';') {",
       "            if let Some((key, value)) = pair.trim().split_once('=') {",
       "                if key == name {",
       "                    return Some(axum_dsl_cookie_unquote(value));",
       "                }",
       "            }",
       "        }",
       "    }",
       "    None",
       "}",
       ""]
    end

    def raw_set_lines
      ["fn axum_dsl_set_cookie_raw(name: &str, value: &str, http_only: bool, same_site: &str, secure: bool, max_age: Option<i64>) -> String {",
       *cookie_attribute_lines("axum_dsl_cookie_quote(value)"),
       "}",
       ""]
    end

    # The Rust of the cookie runtime: each signed format's sign and verify, then what is common to every
    # format (the Cookie header, the Set-Cookie lines, and putting them on a response). Each function is
    # emitted only when a body uses it, so the crate has no dead code.
    def runtime_lines(ir)
      decl = ir["cookies"]
      reads = read_formats(decl)
      writes = set_formats(decl)
      out = ["// signed cookies (cookies secret: :#{decl['secret']}, format :#{decl['format']}): written by the compiler"]
      if signs?(decl)
        out.concat(["fn axum_dsl_cookie_key() -> &'static [u8] {",
                    "    settings().#{decl['secret']}.as_bytes()",
                    "}",
                    ""])
      end
      (reads + writes).uniq.each do |format|
        out.concat(backend(format).items(read: reads.include?(format), set: writes.include?(format)))
      end
      out.concat(quote_lines) if decl["unsigned_write"] || writes.any? { |format| format != "hmac" }
      out.concat(unquote_lines) if decl["unsigned_read"] || reads.any? { |format| format != "hmac" }
      reads.each { |format| out.concat(read_lines(format)) }
      out.concat(raw_read_lines) if decl["unsigned_read"]
      writes.each { |format| out.concat(set_lines(format)) }
      out.concat(raw_set_lines) if decl["unsigned_write"]
      if decl["delete"]
        out.concat(["fn axum_dsl_delete_cookie(name: &str) -> String {",
                    "    format!(\"{name}=; Path=/; Max-Age=0\")",
                    "}",
                    ""])
      end
      out.concat([
        "fn axum_dsl_apply_cookies(response: &mut ::axum::response::Response, cookies: &[String]) {",
        "    for cookie in cookies {",
        "        if let Ok(value) = ::axum::http::HeaderValue::from_str(cookie) {",
        "            response.headers_mut().append(::axum::http::header::SET_COOKIE, value);",
        "        }",
        "    }",
        "}"
      ]) if writes.any? || decl["unsigned_write"] || decl["delete"]
      out
    end
  end
end
