# frozen_string_literal: true

module AxumDsl
  # multipart/form-data (docs/dsl.md, "Uploads"), the encoding a browser uses for a form with a file input. Rack
  # parses it for a Rails app; here the compiler writes the parser into the crate, with no crate of its own.
  #
  # Two things need it:
  #   * a params group with an `:upload` field. Its form is read by AxumDslForm, which answers a urlencoded body
  #     exactly as axum's `Form` does and a multipart body as Rack does: the text parts become the group's
  #     `in: :form` fields (bracketed wire names such as `user[bio]` included, the last one of a repeated name
  #     wins), and a file part becomes an `AxumDslUpload` (filename, content type, size, MD5 checksum, bytes) for
  #     the `:upload` field named by it. A file part whose filename is empty is a file input nobody chose a file
  #     in: Rack drops it, so the field is nil. A group without an `:upload` field keeps axum's `Form`.
  #   * `use_layer :method_override`, which reads a multipart body's `_method` text part as Rack::MethodOverride
  #     does (Rack parses the body to find it).
  # The body is read into memory (LIMIT, 413 beyond it: Rails has no limit of its own, so this is a memory guard),
  # parsed with Rack's part limits (4096 parts, 128 files, 413 beyond them) and a malformed body is a 400.
  #
  # `upload.store(root)` is the Disk service's upload: a fresh key (has_secure_token style, 28 lowercase base36
  # characters) and the file at <root>/<key[0,2]>/<key[2,2]>/<key>.
  module Multipart
    module_function

    LIMIT = 128 * 1024 * 1024
    PART_LIMIT = 4096
    FILE_LIMIT = 128
    STORE = "upload_store"

    def uploads?(ir) = ir["params"].to_a.any? { |p| p["fields"].to_a.any? { |f| f["type"] == "upload" } }

    # A form field that is a list reads every repeated key (Rails' `user_ids[]`), which axum's Form cannot.
    LIST_TYPES = %w[string_list i64_list f64_list].freeze

    def extras?(fields) = fields.any? { |f| f["type"] == "upload" || LIST_TYPES.include?(f["type"]) }

    # Some params group is read by AxumDslForm (it has an :upload or a list field in a form).
    def forms?(ir)
      ir["routes"].to_a.any? do |r|
        prm = ir["params"].to_a.find { |x| x["name"] == r["params"] }
        prm && prm["fields"].any? { |f| (r["field_in"] || {})[f["name"]] == "form" && (f["type"] == "upload" || LIST_TYPES.include?(f["type"])) }
      end
    end

    def stores?(ir) = ir["builtins"].to_a.include?(STORE)

    # The parser is needed by an upload form and by the method override layer.
    def used?(ir) = forms?(ir) || ir["layers"].to_a.any? { |l| l["name"] == "method_override" }

    # Cargo.toml lines, each led by a newline (the emitter deduplicates them): the MD5 checksum and its base64 for
    # an upload's `checksum`, and rand for a stored key.
    def deps(ir)
      lines = []
      lines.push("md-5 = \"0.10\"", "base64 = \"0.22\"") if forms?(ir)
      lines.push("rand = \"0.9\"") if stores?(ir)
      lines.map { |line| "\n#{line}" }.join
    end

    # tokio's `fs` writes the stored file; send_file asks for the same feature, so it is named once.
    def tokio_features(ir) = stores?(ir) && !ir["builtins"].to_a.include?("send_file") ? ", \"fs\"" : ""

    # Whether a form part's fields make it read by AxumDslForm instead of axum's Form.
    def upload_form?(fields) = extras?(fields)

    # The Rust that turns one list element's text into its type, or returns the error.
    def element(type)
      case type
      when "string_list" then "Ok::<String, ()>(v.clone())"
      when "i64_list" then "v.parse::<i64>()"
      else "v.parse::<f64>()"
      end
    end

    # For each params struct read from a form with upload or list fields: how to take them out of the parsed body
    # (the other fields were already deserialized from the text pairs).
    def struct_impls(plan)
      plan["structs"].to_a.flat_map do |s|
        next [] unless s["source"] == "form" && extras?(s["fields"])

        files = s["fields"].select { |f| f["type"] == "upload" }
        lists = s["fields"].select { |f| LIST_TYPES.include?(f["type"]) }
        out = ["impl AxumDslFormExtras for #{s['name']} {"]
        unless lists.empty?
          names = lists.map { |f| AxumDsl.rstr(f["wire_name"] || f["name"]) }.join(", ")
          out << "    fn list_names() -> &'static [&'static str] {"
          out << "        &[#{names}]"
          out << "    }"
          out << ""
          out << "    fn take_lists(&mut self, pairs: &[(String, String)]) -> Result<(), String> {"
          lists.each do |f|
            wire = AxumDsl.rstr(f["wire_name"] || f["name"])
            absent =
              if f["optional"] then "// absent: nil"
              elsif f.key?("default") then "self.#{f['name']} = #{Emit.default_name(s['name'], f)}();"
              else "return Err(format!(\"missing field `{}`\", #{wire}));"
              end
            out.concat([
              "        {",
              "            let found: Vec<&String> = pairs.iter().filter(|(name, _)| name == #{wire}).map(|(_, v)| v).collect();",
              "            if found.is_empty() {",
              "                #{absent}",
              "            } else {",
              "                let mut list = Vec::new();",
              "                for v in found {",
              "                    match #{element(f['type'])} {",
              "                        Ok(item) => list.push(item),",
              "                        Err(_) => return Err(format!(\"invalid value for {}: {:?}\", #{wire}, v)),",
              "                    }",
              "                }",
              "                self.#{f['name']} = #{f['optional'] ? 'Some(list)' : 'list'};",
              "            }",
              "        }"
            ])
          end
          out << "        Ok(())"
          out << "    }"
        end
        unless files.empty?
          out << "" unless lists.empty?
          out << "    fn take_uploads(&mut self, files: &mut Vec<(String, AxumDslUpload)>) {"
          files.each { |f| out << "        self.#{f['name']} = axum_dsl_take_upload(files, #{AxumDsl.rstr(f['wire_name'] || f['name'])});" }
          out << "    }"
        end
        out << "}" << ""
      end
    end

    def items(ir)
      return [] unless used?(ir)

      out = ["// multipart/form-data (see lib/axum_dsl/multipart.rb): the parser, an upload form's extractor and a stored upload: written by the compiler"]
      out.concat(parser.lines.map(&:chomp))
      out << "const AXUM_DSL_MULTIPART_LIMIT: usize = #{LIMIT};"
      out << ""
      if forms?(ir)
        out.concat(uploads.lines.map(&:chomp))
        out << ""
      end
      if stores?(ir)
        out.concat(store.lines.map(&:chomp))
        out << ""
      end
      out
    end

    def parser
      <<~'RS'
        // One part of a multipart body: the field name, the filename when the part is a file, its Content-Type and
        // where its bytes sit in the body.
        #[allow(dead_code)]
        struct AxumDslPart {
            name: String,
            filename: Option<String>,
            content_type: Option<String>,
            data: ::std::ops::Range<usize>,
        }

        #[allow(dead_code)]
        fn axum_dsl_find(hay: &[u8], needle: &[u8], from: usize) -> Option<usize> {
            if needle.is_empty() || hay.len() < needle.len() || from > hay.len() - needle.len() {
                return None;
            }
            hay[from..].windows(needle.len()).position(|window| window == needle).map(|at| at + from)
        }

        // The boundary of a `multipart/form-data; boundary=...` Content-Type.
        #[allow(dead_code)]
        fn axum_dsl_multipart_boundary(content_type: &str) -> Option<String> {
            for param in content_type.split(';').skip(1) {
                if let Some((key, value)) = param.trim().split_once('=') {
                    let value = value.trim().trim_matches('"');
                    if key.trim().eq_ignore_ascii_case("boundary") && !value.is_empty() {
                        return Some(value.to_string());
                    }
                }
            }
            None
        }

        // Whether a Content-Type names a multipart form.
        #[allow(dead_code)]
        fn axum_dsl_is_multipart(content_type: &str) -> bool {
            content_type.trim_start().to_ascii_lowercase().starts_with("multipart/form-data")
        }

        // The value of one parameter of a header (`name` in `form-data; name="x"; filename="y"`), unquoted.
        #[allow(dead_code)]
        fn axum_dsl_header_param(value: &str, key: &str) -> Option<String> {
            let mut segments = Vec::new();
            let mut current = String::new();
            let mut quoted = false;
            let mut escaped = false;
            for c in value.chars() {
                if escaped {
                    escaped = false;
                    current.push(c);
                } else if quoted && c == '\\' {
                    escaped = true;
                    current.push(c);
                } else if c == '"' {
                    quoted = !quoted;
                    current.push(c);
                } else if c == ';' && !quoted {
                    segments.push(::std::mem::take(&mut current));
                } else {
                    current.push(c);
                }
            }
            segments.push(current);
            for segment in segments.iter().skip(1) {
                if let Some((name, raw)) = segment.trim().split_once('=') {
                    if name.trim().eq_ignore_ascii_case(key) {
                        let raw = raw.trim();
                        if raw.len() >= 2 && raw.starts_with('"') && raw.ends_with('"') {
                            let mut text = String::new();
                            let mut chars = raw[1..raw.len() - 1].chars();
                            while let Some(c) = chars.next() {
                                if c == '\\' {
                                    if let Some(next) = chars.next() {
                                        text.push(next);
                                    }
                                } else {
                                    text.push(c);
                                }
                            }
                            return Some(text);
                        }
                        return Some(raw.to_string());
                    }
                }
            }
            None
        }

        // A filename as Rack hands it over: percent escapes decoded when every `%` starts a valid escape (browsers
        // write a quote in a name as %22).
        #[allow(dead_code)]
        fn axum_dsl_filename(raw: &str) -> String {
            let bytes = raw.as_bytes();
            let valid = bytes
                .iter()
                .enumerate()
                .all(|(i, byte)| *byte != b'%' || (i + 2 < bytes.len() && bytes[i + 1].is_ascii_hexdigit() && bytes[i + 2].is_ascii_hexdigit()));
            if !valid || !raw.contains('%') {
                return raw.to_string();
            }
            let mut out = Vec::with_capacity(bytes.len());
            let mut i = 0;
            while i < bytes.len() {
                if bytes[i] == b'%' {
                    let high = (bytes[i + 1] as char).to_digit(16).unwrap_or(0);
                    let low = (bytes[i + 2] as char).to_digit(16).unwrap_or(0);
                    out.push((high * 16 + low) as u8);
                    i += 3;
                } else {
                    out.push(bytes[i]);
                    i += 1;
                }
            }
            String::from_utf8_lossy(&out).into_owned()
        }

        // The parts of a multipart body, or the status Rack/Rails answer with: 400 for a body that is not well formed
        // (a missing closing boundary included), 413 past 4096 parts or 128 files.
        #[allow(dead_code)]
        fn axum_dsl_multipart_parse(body: &[u8], boundary: &str) -> Result<Vec<AxumDslPart>, ::axum::http::StatusCode> {
            let bad = ::axum::http::StatusCode::BAD_REQUEST;
            let too_big = ::axum::http::StatusCode::PAYLOAD_TOO_LARGE;
            let delimiter = format!("--{boundary}").into_bytes();
            let mut closing = b"\r\n".to_vec();
            closing.extend_from_slice(&delimiter);
            let mut parts: Vec<AxumDslPart> = Vec::new();
            let mut files = 0usize;
            let mut at = match axum_dsl_find(body, &delimiter, 0) {
                Some(at) => at,
                None => return Err(bad),
            };
            loop {
                at += delimiter.len();
                if body[at..].starts_with(b"--") {
                    return Ok(parts);
                }
                let line_end = match axum_dsl_find(body, b"\r\n", at) {
                    Some(line_end) => line_end,
                    None => return Err(bad),
                };
                if !body[at..line_end].iter().all(|byte| *byte == b' ' || *byte == b'\t') {
                    return Err(bad);
                }
                let head_start = line_end + 2;
                let (head_end, data_start) = if body[head_start..].starts_with(b"\r\n") {
                    (head_start, head_start + 2)
                } else {
                    match axum_dsl_find(body, b"\r\n\r\n", head_start) {
                        Some(end) => (end, end + 4),
                        None => return Err(bad),
                    }
                };
                let data_end = match axum_dsl_find(body, &closing, data_start) {
                    Some(data_end) => data_end,
                    None => return Err(bad),
                };
                let mut name = None;
                let mut filename = None;
                let mut content_type = None;
                for line in String::from_utf8_lossy(&body[head_start..head_end]).split("\r\n") {
                    if let Some((header, value)) = line.split_once(':') {
                        if header.trim().eq_ignore_ascii_case("content-disposition") {
                            name = axum_dsl_header_param(value, "name");
                            filename = axum_dsl_header_param(value, "filename").map(|raw| axum_dsl_filename(&raw));
                        } else if header.trim().eq_ignore_ascii_case("content-type") {
                            content_type = Some(value.trim().to_string());
                        }
                    }
                }
                if let Some(name) = name {
                    if parts.len() >= 4096 {
                        return Err(too_big);
                    }
                    if filename.as_deref().map_or(false, |f| !f.is_empty()) {
                        files += 1;
                        if files > 128 {
                            return Err(too_big);
                        }
                    }
                    parts.push(AxumDslPart { name, filename, content_type, data: data_start..data_end });
                }
                at = data_end + 2;
            }
        }
      RS
    end


    def uploads
      <<~'RS'
        // A file from a multipart form (an `:upload` field): what Rack's UploadedFile holds, plus the MD5 checksum
        // Active Storage records for a blob.
        #[derive(Clone)]
        #[allow(dead_code)]
        struct AxumDslUpload {
            filename: String,
            content_type: String,
            size: i64,
            checksum: String,
            metadata: String,
            bytes: Vec<u8>,
        }

        // Active Storage's checksum: the base64 of the MD5 digest of the whole file.
        #[allow(dead_code)]
        fn axum_dsl_upload_checksum(data: &[u8]) -> String {
            use ::md5::Digest;
            ::base64::Engine::encode(&::base64::engine::general_purpose::STANDARD, ::md5::Md5::digest(data))
        }

        // The blob metadata Active Storage writes once a file is identified and analyzed: ImageAnalyzer's width and height
        // for an image, in the order Rails' JSON has them. The size is read from the header of a JPEG, PNG, GIF or WebP;
        // EXIF orientation is not applied (vips swaps the two for a rotated JPEG). Any other file is identified only.
        #[allow(dead_code)]
        fn axum_dsl_upload_metadata(data: &[u8]) -> String {
            match axum_dsl_image_size(data) {
                Some((width, height)) => format!(r#"{{"identified":true,"width":{width},"height":{height},"analyzed":true}}"#),
                None => r#"{"identified":true,"analyzed":true}"#.to_string(),
            }
        }

        #[allow(dead_code)]
        fn axum_dsl_image_size(d: &[u8]) -> Option<(u32, u32)> {
            let be16 = |i: usize| Some(u16::from_be_bytes([*d.get(i)?, *d.get(i + 1)?]) as u32);
            let le16 = |i: usize| Some(u16::from_le_bytes([*d.get(i)?, *d.get(i + 1)?]) as u32);
            let le24 = |i: usize| Some(u32::from_le_bytes([*d.get(i)?, *d.get(i + 1)?, *d.get(i + 2)?, 0]));
            if d.starts_with(b"\x89PNG\r\n\x1a\n") && d.get(12..16) == Some(b"IHDR") {
                let be32 = |i: usize| Some(u32::from_be_bytes(d.get(i..i + 4)?.try_into().ok()?));
                return Some((be32(16)?, be32(20)?));
            }
            if d.starts_with(b"GIF87a") || d.starts_with(b"GIF89a") {
                return Some((le16(6)?, le16(8)?));
            }
            if d.get(0..4) == Some(b"RIFF") && d.get(8..12) == Some(b"WEBP") {
                return match d.get(12..16)? {
                    b"VP8 " => Some((le16(26)? & 0x3fff, le16(28)? & 0x3fff)),
                    b"VP8L" => {
                        let b = d.get(21..25)?;
                        let (b0, b1, b2, b3) = (b[0] as u32, b[1] as u32, b[2] as u32, b[3] as u32);
                        Some((1 + (((b1 & 0x3f) << 8) | b0), 1 + (((b3 & 0x0f) << 10) | (b2 << 2) | ((b1 & 0xc0) >> 6))))
                    }
                    b"VP8X" => Some((1 + le24(24)?, 1 + le24(27)?)),
                    _ => None,
                };
            }
            if d.starts_with(&[0xff, 0xd8]) {
                let mut i = 2;
                while i + 4 <= d.len() {
                    if d[i] != 0xff {
                        return None;
                    }
                    let marker = d[i + 1];
                    if marker == 0xff {
                        i += 1;
                        continue;
                    }
                    if marker == 0x01 || (0xd0..=0xd8).contains(&marker) {
                        i += 2;
                        continue;
                    }
                    let length = be16(i + 2)? as usize;
                    // SOF0..SOF15, but DHT (c4), JPG (c8) and DAC (cc) are not frame headers.
                    if (0xc0..=0xcf).contains(&marker) && ![0xc4, 0xc8, 0xcc].contains(&marker) {
                        return Some((be16(i + 7)?, be16(i + 5)?));
                    }
                    i += 2 + length;
                }
            }
            None
        }

        // What a params struct takes out of a form besides its plain text fields: the wire names of its list fields
        // (every repeated key, Rails' `user_ids[]`), and its files by the wire name of each `:upload` field.
        #[allow(dead_code)]
        trait AxumDslFormExtras {
            fn list_names() -> &'static [&'static str] {
                &[]
            }
            fn take_lists(&mut self, _pairs: &[(String, String)]) -> Result<(), String> {
                Ok(())
            }
            fn take_uploads(&mut self, _files: &mut Vec<(String, AxumDslUpload)>) {}
        }

        #[allow(dead_code)]
        fn axum_dsl_take_upload(files: &mut Vec<(String, AxumDslUpload)>, name: &str) -> Option<AxumDslUpload> {
            let at = files.iter().rposition(|(field, _)| field == name)?;
            Some(files.remove(at).1)
        }

        // One value of a urlencoded body: everything but the unreserved characters is %-escaped.
        #[allow(dead_code)]
        fn axum_dsl_urlencode(out: &mut String, text: &str) {
            for byte in text.bytes() {
                if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b'~') {
                    out.push(char::from(byte));
                } else {
                    out.push_str(&format!("%{byte:02X}"));
                }
            }
        }

        // One name or value of a urlencoded body, with `+` and `%XX` decoded; a malformed escape is kept literally.
        #[allow(dead_code)]
        fn axum_dsl_urldecode(input: &[u8]) -> String {
            let mut out = Vec::with_capacity(input.len());
            let mut i = 0;
            while i < input.len() {
                match input[i] {
                    b'+' => {
                        out.push(b' ');
                        i += 1;
                    }
                    b'%' if i + 2 < input.len() && input[i + 1].is_ascii_hexdigit() && input[i + 2].is_ascii_hexdigit() => {
                        let high = (input[i + 1] as char).to_digit(16).unwrap_or(0);
                        let low = (input[i + 2] as char).to_digit(16).unwrap_or(0);
                        out.push((high * 16 + low) as u8);
                        i += 3;
                    }
                    byte => {
                        out.push(byte);
                        i += 1;
                    }
                }
            }
            String::from_utf8_lossy(&out).into_owned()
        }

        // A form group with an `:upload` or a list field, urlencoded or multipart. Both bodies become name/value
        // pairs (Rack's parsers do the same): a repeated list key keeps every value, any other repeated key its
        // last, and the pairs go to axum's Form as one urlencoded body, so the same deserializer, wire names and
        // errors apply to the plain fields. The list fields and the files are then taken by the struct itself.
        #[allow(dead_code)]
        struct AxumDslForm<T>(T);

        impl<S, T> ::axum::extract::FromRequest<S> for AxumDslForm<T>
        where
            S: Send + Sync,
            T: ::serde::de::DeserializeOwned + AxumDslFormExtras,
        {
            type Rejection = ::axum::response::Response;

            async fn from_request(req: ::axum::extract::Request, state: &S) -> Result<Self, Self::Rejection> {
                let content_type = req
                    .headers()
                    .get(::axum::http::header::CONTENT_TYPE)
                    .and_then(|value| value.to_str().ok())
                    .unwrap_or("")
                    .to_string();
                let multipart = axum_dsl_is_multipart(&content_type);
                let urlencoded = content_type.split(';').next().unwrap_or("").trim().eq_ignore_ascii_case("application/x-www-form-urlencoded");
                if !multipart && !urlencoded {
                    // axum's own answer (415) for a body that is no form
                    return match <::axum::extract::Form<T> as ::axum::extract::FromRequest<S>>::from_request(req, state).await {
                        Ok(::axum::extract::Form(value)) => Ok(AxumDslForm(value)),
                        Err(rejection) => Err(::axum::response::IntoResponse::into_response(rejection)),
                    };
                }
                let status_response = |status: ::axum::http::StatusCode| {
                    let mut response = ::axum::response::IntoResponse::into_response(status.canonical_reason().unwrap_or("bad request"));
                    *response.status_mut() = status;
                    response
                };
                let limit = if multipart { AXUM_DSL_MULTIPART_LIMIT } else { 2 * 1024 * 1024 };
                let bytes = match ::axum::body::to_bytes(req.into_body(), limit).await {
                    Ok(bytes) => bytes,
                    Err(_) => return Err(status_response(::axum::http::StatusCode::PAYLOAD_TOO_LARGE)),
                };
                let mut all: Vec<(String, String)> = Vec::new();
                let mut files: Vec<(String, AxumDslUpload)> = Vec::new();
                if multipart {
                    let boundary = match axum_dsl_multipart_boundary(&content_type) {
                        Some(boundary) => boundary,
                        None => return Err(status_response(::axum::http::StatusCode::BAD_REQUEST)),
                    };
                    let parts = match axum_dsl_multipart_parse(&bytes, &boundary) {
                        Ok(parts) => parts,
                        Err(status) => return Err(status_response(status)),
                    };
                    for part in parts {
                        let data = &bytes[part.data.clone()];
                        match part.filename {
                            // no file chosen: Rack drops the part, the param is absent
                            Some(filename) if filename.is_empty() => {}
                            Some(filename) => files.push((
                                part.name,
                                AxumDslUpload {
                                    filename,
                                    content_type: part.content_type.unwrap_or_else(|| "application/octet-stream".to_string()),
                                    size: data.len() as i64,
                                    checksum: axum_dsl_upload_checksum(data),
                                    metadata: axum_dsl_upload_metadata(data),
                                    bytes: data.to_vec(),
                                },
                            )),
                            None => all.push((part.name, String::from_utf8_lossy(data).into_owned())),
                        }
                    }
                } else {
                    for piece in bytes.split(|byte| *byte == b'&') {
                        if piece.is_empty() {
                            continue;
                        }
                        let (name, value) = match piece.iter().position(|byte| *byte == b'=') {
                            Some(at) => (&piece[..at], &piece[at + 1..]),
                            None => (piece, &[][..]),
                        };
                        all.push((axum_dsl_urldecode(name), axum_dsl_urldecode(value)));
                    }
                }
                let list_names = T::list_names();
                let mut list_pairs: Vec<(String, String)> = Vec::new();
                let mut pairs: Vec<(String, String)> = Vec::new();
                for (name, value) in all {
                    if list_names.contains(&name.as_str()) {
                        list_pairs.push((name, value));
                    } else {
                        match pairs.iter_mut().find(|(have, _)| *have == name) {
                            Some(slot) => slot.1 = value,
                            None => pairs.push((name, value)),
                        }
                    }
                }
                let mut encoded = String::new();
                for (name, value) in &pairs {
                    if !encoded.is_empty() {
                        encoded.push('&');
                    }
                    axum_dsl_urlencode(&mut encoded, name);
                    encoded.push('=');
                    axum_dsl_urlencode(&mut encoded, value);
                }
                let rebuilt = match ::axum::http::Request::builder()
                    .method(::axum::http::Method::POST)
                    .header(::axum::http::header::CONTENT_TYPE, "application/x-www-form-urlencoded")
                    .body(::axum::body::Body::from(encoded))
                {
                    Ok(rebuilt) => rebuilt,
                    Err(_) => return Err(status_response(::axum::http::StatusCode::BAD_REQUEST)),
                };
                match <::axum::extract::Form<T> as ::axum::extract::FromRequest<S>>::from_request(rebuilt, state).await {
                    Ok(::axum::extract::Form(mut value)) => {
                        if let Err(message) = value.take_lists(&list_pairs) {
                            let mut response = ::axum::response::IntoResponse::into_response(message);
                            *response.status_mut() = ::axum::http::StatusCode::UNPROCESSABLE_ENTITY;
                            return Err(response);
                        }
                        value.take_uploads(&mut files);
                        Ok(AxumDslForm(value))
                    }
                    Err(rejection) => Err(::axum::response::IntoResponse::into_response(rejection)),
                }
            }
        }
      RS
    end


    def store
      <<~'RS'
        // upload.store(root): ActiveStorage::Service::DiskService#upload under a fresh key. The key is
        // `has_secure_token :key, length: 28` (SecureRandom.base36), the path <root>/<key[0,2]>/<key[2,2]>/<key>.
        #[allow(dead_code)]
        fn axum_dsl_upload_key() -> String {
            use ::rand::Rng;
            const ALPHABET: &[u8; 36] = b"0123456789abcdefghijklmnopqrstuvwxyz";
            let mut rng = ::rand::rng();
            (0..28).map(|_| char::from(ALPHABET[rng.random_range(0..36)])).collect()
        }

        #[allow(dead_code)]
        async fn axum_dsl_upload_store(upload: &AxumDslUpload, root: &str) -> Result<String, String> {
            let key = axum_dsl_upload_key();
            let dir = ::std::path::Path::new(root).join(&key[0..2]).join(&key[2..4]);
            ::tokio::fs::create_dir_all(&dir).await.map_err(|e| format!("upload: cannot create {}: {e}", dir.display()))?;
            let path = dir.join(&key);
            ::tokio::fs::write(&path, &upload.bytes).await.map_err(|e| format!("upload: cannot write {}: {e}", path.display()))?;
            Ok(key)
        }
      RS
    end
  end
end
