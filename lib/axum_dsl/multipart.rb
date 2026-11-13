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

    REQUEST_UPLOAD = "request_upload"

    # Some route body reads a file part beside its raw body: `request_upload(:name)`.
    def request_upload?(ir) = ir["builtins"].to_a.include?(REQUEST_UPLOAD)

    # The upload value and its checksum are written (an upload form, request_upload or image_variant); and the form
    # runtime with set :merge_query_params, whose merged form reads the same pairs.
    def uploads_used?(ir) = forms?(ir) || request_upload?(ir) || ImageVariant.used?(ir) || ir["merge_query_params"] == true

    # The parser is needed by an upload form and by the method override layer.
    def used?(ir) = uploads_used?(ir) || ir["layers"].to_a.any? { |l| l["name"] == "method_override" }

    # Cargo.toml lines, each led by a newline (the emitter deduplicates them): the MD5 checksum and its base64 for
    # an upload's `checksum`, and rand for a stored key.
    def deps(ir)
      lines = []
      lines.push("md-5 = \"0.10\"", "base64 = \"0.22\"") if uploads_used?(ir)
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
      out << "#[allow(dead_code)]"
    out << "const AXUM_DSL_MULTIPART_LIMIT: usize = #{LIMIT};"
      out << ""
      if uploads_used?(ir)
        out.concat(uploads.lines.map(&:chomp))
        out.concat(merged_form(ir["merge_query_params"] == true))
        out.concat(marcel_tables)
        out << ""
      end
      if request_upload?(ir)
        out.concat(request_upload.lines.map(&:chomp))
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


    # request_upload(:name): Rack's params[name] for a multipart body, when it is a file: the last file part of that
    # name (Rack's last value wins), nil for a body that is not multipart or does not parse, or a part with no file.
    def request_upload
      <<~'RS'
        #[allow(dead_code)]
        fn axum_dsl_request_upload(headers: &::axum::http::HeaderMap, body: &[u8], name: &str) -> Option<AxumDslUpload> {
            let content_type = headers.get(::axum::http::header::CONTENT_TYPE)?.to_str().ok()?;
            if !axum_dsl_is_multipart(content_type) || body.len() > AXUM_DSL_MULTIPART_LIMIT {
                return None;
            }
            let boundary = axum_dsl_multipart_boundary(content_type)?;
            let parts = axum_dsl_multipart_parse(body, &boundary).ok()?;
            let mut found = None;
            for part in parts {
                if part.name != name {
                    continue;
                }
                let data = &body[part.data.clone()];
                found = match part.filename {
                    Some(filename) if !filename.is_empty() => Some(AxumDslUpload {
                        content_type: axum_dsl_identify_content_type(data, &filename, part.content_type.as_deref()),
                        filename,
                        size: data.len() as i64,
                        checksum: axum_dsl_upload_checksum(data),
                        metadata: axum_dsl_upload_metadata(data),
                        bytes: data.to_vec(),
                    }),
                    _ => None,
                };
            }
            found
        }
      RS
    end

    MARCEL = File.join(__dir__, "data", "marcel-1.1.0.json")

    # set :merge_query_params (Rails' `params`: query_parameters.merge(request_parameters)): the switch the upload form
    # reads, the query's pairs, and AxumDslMergedForm, a plain form group's extractor: the query string's pairs whose
    # name the urlencoded body does not carry, then the body's, deserialized by axum's Form as one body.
    def merged_form(on)
      <<~RS.lines.map(&:chomp)
        #[allow(dead_code)]
        const AXUM_DSL_MERGE_QUERY_PARAMS: bool = #{on};

        #[allow(dead_code)]
        fn axum_dsl_query_pairs(query: &str) -> Vec<(String, String)> {
            query
                .split('&')
                .filter(|piece| !piece.is_empty())
                .map(|piece| match piece.split_once('=') {
                    Some((name, value)) => (axum_dsl_urldecode(name.as_bytes()), axum_dsl_urldecode(value.as_bytes())),
                    None => (axum_dsl_urldecode(piece.as_bytes()), String::new()),
                })
                .collect()
        }

        #[allow(dead_code)]
        struct AxumDslMergedForm<T>(T);

        impl<S, T> ::axum::extract::FromRequest<S> for AxumDslMergedForm<T>
        where
            S: Send + Sync,
            T: ::serde::de::DeserializeOwned,
        {
            type Rejection = ::axum::response::Response;

            async fn from_request(req: ::axum::extract::Request, state: &S) -> Result<Self, Self::Rejection> {
                let (mut parts, body) = req.into_parts();
                let content_type = parts.headers.get(::axum::http::header::CONTENT_TYPE).and_then(|v| v.to_str().ok()).unwrap_or("").to_string();
                let urlencoded = content_type.split(';').next().unwrap_or("").trim().eq_ignore_ascii_case("application/x-www-form-urlencoded");
                let bytes = match ::axum::body::to_bytes(body, 2 * 1024 * 1024).await {
                    Ok(bytes) => bytes,
                    Err(_) => {
                        let mut response = ::axum::response::IntoResponse::into_response("payload too large");
                        *response.status_mut() = ::axum::http::StatusCode::PAYLOAD_TOO_LARGE;
                        return Err(response);
                    }
                };
                // A body that is no form (and is not empty) is axum Form's own answer, as without the merge.
                if !urlencoded && !bytes.is_empty() {
                    let req = ::axum::extract::Request::from_parts(parts, ::axum::body::Body::from(bytes));
                    return match <::axum::extract::Form<T> as ::axum::extract::FromRequest<S>>::from_request(req, state).await {
                        Ok(::axum::extract::Form(value)) => Ok(AxumDslMergedForm(value)),
                        Err(rejection) => Err(::axum::response::IntoResponse::into_response(rejection)),
                    };
                }
                let body_text = String::from_utf8_lossy(&bytes).into_owned();
                let body_names: Vec<String> = axum_dsl_query_pairs(&body_text).into_iter().map(|(name, _)| name).collect();
                let mut pieces: Vec<&str> = parts
                    .uri
                    .query()
                    .unwrap_or("")
                    .split('&')
                    .filter(|piece| !piece.is_empty())
                    .filter(|piece| !body_names.contains(&axum_dsl_urldecode(piece.split('=').next().unwrap_or("").as_bytes())))
                    .collect();
                pieces.extend(body_text.split('&').filter(|piece| !piece.is_empty()));
                let merged = pieces.join("&");
                parts.headers.insert(::axum::http::header::CONTENT_TYPE, ::axum::http::HeaderValue::from_static("application/x-www-form-urlencoded"));
                parts.headers.remove(::axum::http::header::CONTENT_LENGTH);
                let req = ::axum::extract::Request::from_parts(parts, ::axum::body::Body::from(merged));
                match <::axum::extract::Form<T> as ::axum::extract::FromRequest<S>>::from_request(req, state).await {
                    Ok(::axum::extract::Form(value)) => Ok(AxumDslMergedForm(value)),
                    Err(rejection) => Err(::axum::response::IntoResponse::into_response(rejection)),
                }
            }
        }
      RS
    end

    # Marcel 1.1's MAGIC (in its order), EXTENSIONS and TYPE_PARENTS (sorted): its Tika-derived tables (MIT), read from
    # the gem after its definitions.rb has extended them, for the content type an upload is identified as
    # (axum_dsl_identify_content_type).
    def marcel_tables
      data = JSON.parse(File.read(MARCEL))
      exts = data["extensions"].sort_by(&:first).map { |e, t| "    (#{AxumDsl.rstr(e)}, #{AxumDsl.rstr(t)})," }
      parents = data["parents"].sort_by(&:first).map { |t, ps| "    (#{AxumDsl.rstr(t)}, &[#{ps.map { |x| AxumDsl.rstr(x) }.join(', ')}])," }
      rule = lambda do |r|
        at, upto, value, children = r
        bytes = value ? "Some(b\"#{value.unpack1('m0').bytes.map { |b| format('\\x%02x', b) }.join}\")" : "None"
        kids = children ? "Some(&[#{children.map(&rule).join(', ')}])" : "None"
        "AxumDslMarcelRule { at: #{at}, upto: #{upto.nil? ? 'None' : "Some(#{upto})"}, value: #{bytes}, children: #{kids} }"
      end
      magic = data["magic"].map { |t, rules| "    (#{AxumDsl.rstr(t)}, &[#{rules.map(&rule).join(', ')}])," }
      ["#[allow(dead_code)]", "static AXUM_DSL_MARCEL_MAGIC: &[(&str, &[AxumDslMarcelRule])] = &[", *magic, "];",
       "#[allow(dead_code)]", "static AXUM_DSL_MARCEL_EXTENSIONS: &[(&str, &str)] = &[", *exts, "];",
       "#[allow(dead_code)]", "static AXUM_DSL_MARCEL_PARENTS: &[(&str, &[&str])] = &[", *parents, "];"]
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

        // Blob#identify_content_type: `Marcel::MimeType.for(data, name: filename, declared_type: content_type)` (marcel 1.1),
        // for the types Active Storage processes or previews by magic number: the type the bytes declare wins, else the
        // declared type (application/octet-stream counts as none), else the filename's extension, else
        // application/octet-stream. Marcel's `most_specific_type` keeps a later candidate only when it is a subtype of the
        // magic one, and none of these types has subtypes. A file whose magic is another type keeps its declared type here,
        // where Marcel's full table may name it (a ZIP declared as application/octet-stream, say).
        #[allow(dead_code)]
        fn axum_dsl_identify_content_type(data: &[u8], filename: &str, declared: Option<&str>) -> String {
            // Marcel::Magic.by_magic over the first 4 KB Active Storage reads (download_identifiable_chunk): the first type
            // in MAGIC's order with a matching rule.
            let chunk = &data[..data.len().min(4096)];
            let magic = AXUM_DSL_MARCEL_MAGIC.iter().find(|(_, rules)| axum_dsl_marcel_match(chunk, rules)).map(|(kind, _)| *kind);
            // parse_media_type: lower case, up to the first `;`, `,` or white space, and it must hold a `/`; octet-stream is
            // treated as no declared type.
            let declared = declared
                .map(|d| d.to_ascii_lowercase())
                .and_then(|d| d.split([';', ',', ' ', '\t', '\n', '\r', '\x0b', '\x0c']).next().map(str::to_owned))
                .filter(|d| d.contains('/') && d != "application/octet-stream");
            // Marcel::Magic.by_path: File.extname of the name (leading dots are not an extension), looked up lower-cased.
            let base = filename.rsplit('/').next().unwrap_or(filename);
            let trimmed = base.trim_start_matches('.');
            let extension = trimmed.rfind('.').map(|at| trimmed[at + 1..].to_ascii_lowercase()).unwrap_or_default();
            let by_name = AXUM_DSL_MARCEL_EXTENSIONS
                .binary_search_by(|(ext, _)| (*ext).cmp(extension.as_str()))
                .ok()
                .map(|at| AXUM_DSL_MARCEL_EXTENSIONS[at].1.to_string());
            // most_specific_type(magic, declared, by name, binary): the first, unless a later one is a subtype of it.
            let mut candidates: Vec<String> = Vec::new();
            for candidate in [magic.map(str::to_string), declared, by_name, Some("application/octet-stream".to_string())].into_iter().flatten() {
                if !candidates.contains(&candidate) {
                    candidates.push(candidate);
                }
            }
            let mut chosen = candidates[0].clone();
            for candidate in &candidates[1..] {
                if axum_dsl_marcel_child(candidate, &chosen) {
                    chosen = candidate.clone();
                }
            }
            chosen
        }

        // One rule of Marcel's MAGIC: `value` at `at`, or anywhere in at..=upto (the bytes from `at` through upto plus the
        // value's length), and then one of `children`, read from the start again (magic_match_io over a StringIO).
        #[allow(dead_code)]
        struct AxumDslMarcelRule {
            at: usize,
            upto: Option<usize>,
            value: Option<&'static [u8]>,
            children: Option<&'static [AxumDslMarcelRule]>,
        }

        #[allow(dead_code)]
        fn axum_dsl_marcel_match(data: &[u8], rules: &[AxumDslMarcelRule]) -> bool {
            rules.iter().any(|rule| {
                let Some(value) = rule.value else { return false };
                let found = match rule.upto {
                    Some(upto) if rule.at < data.len() => {
                        let window = &data[rule.at..data.len().min(upto + value.len())];
                        value.is_empty() || window.windows(value.len()).any(|w| w == value)
                    }
                    Some(_) => false,
                    None => data.get(rule.at..rule.at + value.len()) == Some(value),
                };
                found && rule.children.is_none_or(|children| axum_dsl_marcel_match(data, children))
            })
        }

        // Marcel::Magic.child?: the type itself, or one of its parents (TYPE_PARENTS, transitively) is the other.
        #[allow(dead_code)]
        fn axum_dsl_marcel_child(child: &str, parent: &str) -> bool {
            child == parent
                || AXUM_DSL_MARCEL_PARENTS
                    .binary_search_by(|(kind, _)| (*kind).cmp(child))
                    .ok()
                    .is_some_and(|at| AXUM_DSL_MARCEL_PARENTS[at].1.iter().any(|p| axum_dsl_marcel_child(p, parent)))
        }

        // The blob metadata Active Storage writes once a file is identified and analyzed: ImageAnalyzer::Vips's width and
        // height for an image, in the order Rails' JSON has them. The size is read from the header of a JPEG, PNG, GIF,
        // WebP or TIFF (or a simple SVG's attributes), and swapped as Rails swaps it: when the EXIF orientation's name matches /Right-top|Left-bottom|Top-right|
        // Bottom-left/ (orientations 6, 8, 2 and 4: Rails' list, which turns 2 and 4 rather than 5 and 7). Any other file is
        // identified only.
        #[allow(dead_code)]
        fn axum_dsl_upload_metadata(data: &[u8]) -> String {
            match axum_dsl_image_size(data) {
                Some((width, height)) => {
                    let (width, height) = if matches!(axum_dsl_exif_orientation(data), Some(2 | 4 | 6 | 8)) { (height, width) } else { (width, height) };
                    format!(r#"{{"identified":true,"width":{width},"height":{height},"analyzed":true}}"#)
                }
                None => r#"{"identified":true,"analyzed":true}"#.to_string(),
            }
        }

        // The EXIF Orientation (IFD0 tag 0x0112) libvips reads: a JPEG's first APP1 "Exif" segment, a PNG's eXIf chunk or
        // a WebP's EXIF chunk, each a TIFF structure (a WebP's may carry the "Exif\0\0" header too).
        #[allow(dead_code)]
        fn axum_dsl_exif_orientation(d: &[u8]) -> Option<u16> {
            let tiff: &[u8] = if d.starts_with(&[0xff, 0xd8]) {
                let mut i = 2;
                loop {
                    if d.get(i) != Some(&0xff) {
                        return None;
                    }
                    let marker = *d.get(i + 1)?;
                    if marker == 0xda || marker == 0xd9 {
                        return None;
                    }
                    let length = u16::from_be_bytes([*d.get(i + 2)?, *d.get(i + 3)?]) as usize;
                    let segment = d.get(i + 4..i + 2 + length)?;
                    if marker == 0xe1 && segment.starts_with(b"Exif\0\0") {
                        break &segment[6..];
                    }
                    i += 2 + length;
                }
            } else if d.starts_with(b"\x89PNG\r\n\x1a\n") {
                let mut i = 8;
                loop {
                    let length = u32::from_be_bytes(d.get(i..i + 4)?.try_into().ok()?) as usize;
                    let kind = d.get(i + 4..i + 8)?;
                    if kind == b"eXIf" {
                        break d.get(i + 8..i + 8 + length)?;
                    }
                    if kind == b"IDAT" || kind == b"IEND" {
                        return None;
                    }
                    i += 12 + length;
                }
            } else if d.get(0..4) == Some(b"RIFF") && d.get(8..12) == Some(b"WEBP") {
                let mut i = 12;
                loop {
                    let kind = d.get(i..i + 4)?;
                    let length = u32::from_le_bytes(d.get(i + 4..i + 8)?.try_into().ok()?) as usize;
                    if kind == b"EXIF" {
                        let chunk = d.get(i + 8..i + 8 + length)?;
                        break chunk.strip_prefix(b"Exif\0\0").unwrap_or(chunk);
                    }
                    i += 8 + length + (length & 1);
                }
            } else {
                return None;
            };
            let little = match tiff.get(0..2)? {
                b"II" => true,
                b"MM" => false,
                _ => return None,
            };
            let u16_at = |i: usize| -> Option<u16> {
                let b = [*tiff.get(i)?, *tiff.get(i + 1)?];
                Some(if little { u16::from_le_bytes(b) } else { u16::from_be_bytes(b) })
            };
            let u32_at = |i: usize| -> Option<u32> {
                let b: [u8; 4] = tiff.get(i..i + 4)?.try_into().ok()?;
                Some(if little { u32::from_le_bytes(b) } else { u32::from_be_bytes(b) })
            };
            let ifd = u32_at(4)? as usize;
            let entries = u16_at(ifd)? as usize;
            (0..entries).find_map(|n| {
                let entry = ifd + 2 + n * 12;
                (u16_at(entry)? == 0x0112 && u16_at(entry + 2)? == 3).then(|| u16_at(entry + 8)).flatten()
            })
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
            // TIFF: IFD0's ImageWidth (256) and ImageLength (257), SHORT or LONG, the first page vips loads.
            if d.starts_with(b"II*\0") || d.starts_with(b"MM\0*") {
                let little = d[0] == b'I';
                let u16_at = |i: usize| -> Option<u32> {
                    let b = [*d.get(i)?, *d.get(i + 1)?];
                    Some((if little { u16::from_le_bytes(b) } else { u16::from_be_bytes(b) }) as u32)
                };
                let u32_at = |i: usize| -> Option<u32> {
                    let b: [u8; 4] = d.get(i..i + 4)?.try_into().ok()?;
                    Some(if little { u32::from_le_bytes(b) } else { u32::from_be_bytes(b) })
                };
                let ifd = u32_at(4)? as usize;
                let (mut width, mut height) = (None, None);
                for n in 0..u16_at(ifd)? as usize {
                    let entry = ifd + 2 + n * 12;
                    let value = match u16_at(entry + 2)? {
                        3 => u16_at(entry + 8),
                        4 => u32_at(entry + 8),
                        _ => None,
                    };
                    match u16_at(entry)? {
                        256 => width = value,
                        257 => height = value,
                        _ => {}
                    }
                }
                return Some((width?, height?));
            }
            // SVG (librsvg through vips' svgload): the root element's width and height when both are plain or `px` numbers,
            // else its viewBox's; other units and percentages are not read here.
            if let Some(start) = d[..d.len().min(4100)].windows(4).position(|w| w == b"<svg") {
                let rest = &d[start..];
                let tag = ::std::str::from_utf8(&rest[..rest.iter().position(|&b| b == b'>')?]).ok()?;
                let attribute = |name: &str| -> Option<&str> {
                    let mut from = 0;
                    while let Some(at) = tag[from..].find(name) {
                        let at = from + at;
                        let before = tag[..at].chars().last();
                        let after = tag[at + name.len()..].trim_start();
                        if before.is_some_and(char::is_whitespace) && after.starts_with('=') {
                            let value = after[1..].trim_start();
                            let quote = value.chars().next()?;
                            if quote == '"' || quote == '\'' {
                                return value[1..].split(quote).next();
                            }
                        }
                        from = at + name.len();
                    }
                    None
                };
                let pixels = |v: &str| -> Option<u32> {
                    let v = v.trim();
                    let n: f64 = v.strip_suffix("px").unwrap_or(v).trim().parse().ok()?;
                    (n.is_finite() && n > 0.0).then(|| n.round() as u32)
                };
                if let (Some(w), Some(h)) = (attribute("width").and_then(pixels), attribute("height").and_then(pixels)) {
                    return Some((w, h));
                }
                if attribute("width").is_none() && attribute("height").is_none() {
                    let numbers: Vec<f64> = attribute("viewBox")?.split([' ', ',']).filter(|p| !p.is_empty()).filter_map(|p| p.parse().ok()).collect();
                    if numbers.len() == 4 && numbers[2] > 0.0 && numbers[3] > 0.0 {
                        return Some((numbers[2].round() as u32, numbers[3].round() as u32));
                    }
                }
                return None;
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
                let query = req.uri().query().unwrap_or("").to_string();
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
                                    content_type: axum_dsl_identify_content_type(data, &filename, part.content_type.as_deref()),
                                    filename,
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
                // set :merge_query_params: Rails' params, the query string's keys under the body's (a key the body
                // carries, a list included, is the body's alone).
                if AXUM_DSL_MERGE_QUERY_PARAMS {
                    let mut merged: Vec<(String, String)> = axum_dsl_query_pairs(&query)
                        .into_iter()
                        .filter(|(name, _)| !all.iter().any(|(have, _)| have == name) && !files.iter().any(|(have, _)| have == name))
                        .collect();
                    merged.append(&mut all);
                    all = merged;
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

        // upload.store_file(root): `store`, and the file as the fields of the Active Storage blob row it will have (`attach`).
        #[derive(Clone)]
        #[allow(dead_code)]
        struct AxumDslStored {
            key: String,
            filename: String,
            content_type: String,
            size: i64,
            checksum: String,
            metadata: String,
        }

        #[allow(dead_code)]
        async fn axum_dsl_upload_store_file(upload: &AxumDslUpload, root: &str) -> Result<AxumDslStored, String> {
            let key = axum_dsl_upload_store(upload, root).await?;
            Ok(AxumDslStored {
                key,
                filename: upload.filename.clone(),
                content_type: upload.content_type.clone(),
                size: upload.size,
                checksum: upload.checksum.clone(),
                metadata: upload.metadata.clone(),
            })
        }
      RS
    end
  end
end
