# frozen_string_literal: true

module AxumDsl
  # use_layer :method_override (docs/dsl.md): Rack::MethodOverride, which Rails' default middleware stack
  # includes. A browser form can only send GET and POST, so Rails' `form_with model:` and `button_to method:
  # :delete` submit a POST with a hidden `_method=patch|delete` field; this layer turns that POST into the
  # named method before the router sees it.
  #   * only a POST is considered;
  #   * the override is the form field `_method` of an application/x-www-form-urlencoded body or the `_method` text
  #     part of a multipart/form-data body (the last one, as Rack's parser keeps it), else the
  #     `X-HTTP-Method-Override` header; a `_method=` that is present
  #     but empty counts as the field, so the header is not read, as in Rack;
  #   * it is upcased and applies only when it is GET, HEAD, PUT, POST, DELETE, OPTIONS, PATCH, LINK or UNLINK;
  #     anything else leaves the request a POST;
  #   * the body is read once (a urlencoded one up to 2 MiB, axum's own form default, a multipart one up to
  #     Multipart::LIMIT, else 413) and put back unchanged, so the route still reads its form, `_method` included
  #     (a params struct ignores a field it does not name). A multipart body that does not parse is left to the
  #     route, which answers 400; the layer then reads the header.
  # Unlike the other layers it is not a `.layer(..)` on the router: axum's Router::layer runs after the route
  # is matched, too late for a changed method. Emit wraps the finished router (a Router with the original as
  # its fallback), so it runs before routing and outside every other layer, :csrf and :fetch_metadata included:
  # they see the rewritten method, as in Rails, where MethodOverride sits before them.
  module MethodOverride
    BODY_LIMIT = 2 * 1024 * 1024
    METHODS = %w[GET HEAD PUT POST DELETE OPTIONS PATCH LINK UNLINK].freeze

    module_function

    def used?(ir) = ir["layers"].to_a.any? { |l| l["name"] == "method_override" }

    # The finished router, wrapped so the rewrite happens before routing.
    def wrap_lines = ["    let router = axum::Router::new().fallback_service(router).layer(axum::middleware::from_fn(axum_dsl_method_override));"]

    def runtime
      methods = METHODS.map { |m| AxumDsl.rstr(m) }.join(", ")
      <<~RS.lines.map(&:chomp)
        // use_layer :method_override: Rack::MethodOverride, a form's `_method` or X-HTTP-Method-Override as the method: written by the compiler
        const AXUM_DSL_METHOD_OVERRIDE_BODY_LIMIT: usize = #{BODY_LIMIT};
        const AXUM_DSL_METHOD_OVERRIDE_METHODS: &[&str] = &[#{methods}];

        // One application/x-www-form-urlencoded value, with `+` and `%XX` decoded; a malformed escape is kept literally.
        fn axum_dsl_method_override_unquote(input: &[u8]) -> Vec<u8> {
            let mut out = Vec::with_capacity(input.len());
            let mut i = 0;
            while i < input.len() {
                let escaped = match (input[i], input.get(i + 1), input.get(i + 2)) {
                    (b'%', Some(high), Some(low)) => (*high as char).to_digit(16).zip((*low as char).to_digit(16)),
                    _ => None,
                };
                match (input[i], escaped) {
                    (_, Some((high, low))) => {
                        out.push((high * 16 + low) as u8);
                        i += 3;
                    }
                    (b'+', _) => {
                        out.push(b' ');
                        i += 1;
                    }
                    (byte, _) => {
                        out.push(byte);
                        i += 1;
                    }
                }
            }
            out
        }

        // The last `_method` field of a urlencoded body, or None.
        fn axum_dsl_method_override_param(body: &[u8]) -> Option<String> {
            let mut found = None;
            for pair in body.split(|byte| *byte == b'&') {
                let (name, value) = match pair.iter().position(|byte| *byte == b'=') {
                    Some(at) => (&pair[..at], &pair[at + 1..]),
                    None => (pair, &[][..]),
                };
                if axum_dsl_method_override_unquote(name).as_slice() == b"_method" {
                    found = Some(String::from_utf8_lossy(&axum_dsl_method_override_unquote(value)).into_owned());
                }
            }
            found
        }

        // The last `_method` text part of a multipart body, or None (a body that does not parse is the route's to refuse).
        fn axum_dsl_method_override_multipart(content_type: &str, body: &[u8]) -> Option<String> {
            let boundary = axum_dsl_multipart_boundary(content_type)?;
            let parts = axum_dsl_multipart_parse(body, &boundary).ok()?;
            let mut found = None;
            for part in parts {
                if part.filename.is_none() && part.name == "_method" {
                    found = Some(String::from_utf8_lossy(&body[part.data.clone()]).into_owned());
                }
            }
            found
        }

        async fn axum_dsl_method_override(mut request: ::axum::extract::Request, next: ::axum::middleware::Next) -> ::axum::response::Response {
            if request.method() != ::axum::http::Method::POST {
                return next.run(request).await;
            }
            let urlencoded = request
                .headers()
                .get(::axum::http::header::CONTENT_TYPE)
                .and_then(|value| value.to_str().ok())
                .map(|value| value.split(';').next().unwrap_or("").trim().eq_ignore_ascii_case("application/x-www-form-urlencoded"))
                .unwrap_or(false);
            let multipart_type = request
                .headers()
                .get(::axum::http::header::CONTENT_TYPE)
                .and_then(|value| value.to_str().ok())
                .unwrap_or("")
                .to_string();
            let multipart = axum_dsl_is_multipart(&multipart_type);
            let mut wanted = None;
            if urlencoded {
                let (parts, body) = request.into_parts();
                match ::axum::body::to_bytes(body, AXUM_DSL_METHOD_OVERRIDE_BODY_LIMIT).await {
                    Ok(bytes) => {
                        wanted = axum_dsl_method_override_param(&bytes);
                        request = ::axum::http::Request::from_parts(parts, ::axum::body::Body::from(bytes));
                    }
                    Err(_) => {
                        let mut refused = ::axum::response::IntoResponse::into_response("request body is too large");
                        *refused.status_mut() = ::axum::http::StatusCode::PAYLOAD_TOO_LARGE;
                        return refused;
                    }
                }
            }
            else if multipart {
                let (parts, body) = request.into_parts();
                match ::axum::body::to_bytes(body, AXUM_DSL_MULTIPART_LIMIT).await {
                    Ok(bytes) => {
                        wanted = axum_dsl_method_override_multipart(&multipart_type, &bytes);
                        request = ::axum::http::Request::from_parts(parts, ::axum::body::Body::from(bytes));
                    }
                    Err(_) => {
                        let mut refused = ::axum::response::IntoResponse::into_response("request body is too large");
                        *refused.status_mut() = ::axum::http::StatusCode::PAYLOAD_TOO_LARGE;
                        return refused;
                    }
                }
            }
            let wanted = wanted
                .or_else(|| request.headers().get("x-http-method-override").map(|value| String::from_utf8_lossy(value.as_bytes()).into_owned()))
                .unwrap_or_default()
                .to_ascii_uppercase();
            if AXUM_DSL_METHOD_OVERRIDE_METHODS.contains(&wanted.as_str()) {
                if let Ok(method) = ::axum::http::Method::from_bytes(wanted.as_bytes()) {
                    *request.method_mut() = method;
                }
            }
            next.run(request).await
        }
      RS
    end
  end
end
