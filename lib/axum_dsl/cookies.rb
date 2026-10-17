# frozen_string_literal: true

module AxumDsl
  # Signed and plain cookies (docs/sessions.md). `cookies secret: :secret_key` names the setting every signed
  # cookie is signed with; the Rust that reads, writes and verifies cookies is the compiler's own, emitted only
  # for a file that uses it. What a signed cookie looks like on the wire is a format, and the formats live behind
  # the same narrow calls the database adapters do (db/sqlite.rb): `deps` (the Cargo.toml lines) and `items`
  # (the `sign` and `verify` functions). `:hmac` is the default and `:rails` is Rails' MessageVerifier value.
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

    # The format a `cookies` declaration names => the module that emits for it. The hmac format keeps the
    # runtime names it has always had, so a service that does not use format: emits byte-identical code.
    FORMATS = { "hmac" => Hmac, "rails" => RailsMessageVerifier }.freeze

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
    def set_lines(format)
      value = if format == "hmac"
                "axum_dsl_cookie_sign(axum_dsl_cookie_key(), name, value)"
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
