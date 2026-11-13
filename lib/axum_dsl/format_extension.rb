# frozen_string_literal: true

module AxumDsl
  # use_layer :format_extension (docs/dsl.md): Rails' optional `(.:format)` on every route. Rails matches
  # `/messages/1/boosts.turbo_stream` to the `/messages/:id/boosts` route with params[:format] = "turbo_stream", and that
  # format wins over the Accept header (`request.format`). axum's router allows one parameter per path segment and no
  # suffix after one, so the extension cannot be a route of its own; this layer rewrites the request before routing:
  #   * only when the path's last segment ends in `.<format>` (any extension, as Rails' router takes any), the path as
  #     sent matches no route, static mount or served file, and the path without the extension matches a route; a
  #     segment capture takes no `.`, as a Rails segment parameter does not, so `/boosts/5.turbo_stream` is rewritten;
  #   * the extension is taken off the path and `format=<format>` is added to the query (where a params field `format`
  #     or rack_defaults' format check reads it); for a format below, Accept becomes its MIME type, so
  #     `turbo_stream_request?` and every Accept-negotiated answer see the format, as Rails' respond_to does. Another
  #     extension (`/account.873240054`, Rails' `form_with model:` URL for a singular resource) only routes.
  # A path that is a route as sent (`/account/users.turbo_stream`, `/webmanifest.json`) is left alone. Like
  # :method_override it wraps the finished router, outside every other layer.
  module FormatExtension
    # Rails' registered Mime types (action_dispatch/http/mime_types.rb) and turbo-rails' turbo_stream.
    FORMATS = {
      "html" => "text/html", "turbo_stream" => "text/vnd.turbo-stream.html", "json" => "application/json",
      "js" => "text/javascript", "xml" => "application/xml", "text" => "text/plain", "txt" => "text/plain",
      "css" => "text/css", "csv" => "text/csv", "ics" => "text/calendar", "atom" => "application/atom+xml",
      "rss" => "application/rss+xml", "svg" => "image/svg+xml", "png" => "image/png", "jpeg" => "image/jpeg",
      "jpg" => "image/jpeg", "gif" => "image/gif", "webp" => "image/webp", "pdf" => "application/pdf",
      "zip" => "application/zip", "yaml" => "application/x-yaml"
    }.freeze

    module_function

    def used?(ir) = ir["layers"].to_a.any? { |l| l["name"] == "format_extension" }

    # The finished router, wrapped so the rewrite happens before routing (inside :method_override's wrap, which
    # comes after it in main and so runs first).
    def wrap_lines = ["    let router = axum::Router::new().fallback_service(router).layer(axum::middleware::from_fn(axum_dsl_format_extension));"]

    def runtime(ir)
      routes = ir["routes"].to_a.map { |r| r["path"] }.uniq
      routes << ir["openapi"]["path"] if ir["openapi"]
      routes << ir["cable"]["path"] if ir["cable"]
      routes += ir["serve_files"].to_a.map { |f| f["path"] }
      # A static mount answers everything under its prefix (a mount at "/" answers every path, so then no path is
      # rewritten unless a route would take it, which the mount's fallback would not reach first anyway).
      prefixes = ir["statics"].to_a.map { |s| s["prefix"] }.reject { |p| p == "/" }
      formats = FORMATS.map { |f, mime| "(#{AxumDsl.rstr(f)}, #{AxumDsl.rstr(mime)})" }.join(", ")
      <<~RS.lines.map(&:chomp)
        // use_layer :format_extension: Rails' optional `(.:format)`, taken off the path before routing: written by the compiler
        const AXUM_DSL_FORMAT_ROUTES: &[&str] = &[#{routes.map { |p| AxumDsl.rstr(p) }.join(', ')}];
        const AXUM_DSL_FORMAT_MOUNTS: &[&str] = &[#{prefixes.map { |p| AxumDsl.rstr(p) }.join(', ')}];
        const AXUM_DSL_FORMATS: &[(&str, &str)] = &[#{formats}];

        // One path segment against one pattern segment: a literal, `{name}`, or a literal around one `{name}`. A capture
        // takes no `.`, as a Rails segment parameter does not (its default constraint is /[^\/.?]+/), so
        // `/boosts/5.turbo_stream` is not the `/boosts/{id}` route with id "5.turbo_stream"; a `{*splat}` takes dots.
        fn axum_dsl_format_segment(segment: &str, pattern: &str) -> bool {
            match (pattern.find('{'), pattern.rfind('}')) {
                (Some(open), Some(close)) if open < close => {
                    let (prefix, suffix) = (&pattern[..open], &pattern[close + 1..]);
                    segment.len() > prefix.len() + suffix.len()
                        && segment.starts_with(prefix)
                        && segment.ends_with(suffix)
                        && !segment[prefix.len()..segment.len() - suffix.len()].contains('.')
                }
                _ => segment == pattern,
            }
        }

        // Whether a declared route (or mount) answers the path; `{*rest}` takes the rest of it.
        fn axum_dsl_format_routed(path: &str) -> bool {
            if AXUM_DSL_FORMAT_MOUNTS.iter().any(|prefix| path == *prefix || path.starts_with(&format!("{prefix}/"))) {
                return true;
            }
            let segments: Vec<&str> = path.split('/').collect();
            AXUM_DSL_FORMAT_ROUTES.iter().any(|route| {
                let patterns: Vec<&str> = route.split('/').collect();
                if let Some(at) = patterns.iter().position(|p| p.starts_with("{*")) {
                    return segments.len() > at
                        && patterns[..at].iter().zip(&segments[..at]).all(|(p, s)| axum_dsl_format_segment(s, p));
                }
                patterns.len() == segments.len() && patterns.iter().zip(&segments).all(|(p, s)| axum_dsl_format_segment(s, p))
            })
        }

        async fn axum_dsl_format_extension(mut request: ::axum::extract::Request, next: ::axum::middleware::Next) -> ::axum::response::Response {
            let path = request.uri().path().to_string();
            let last = path.rsplit('/').next().unwrap_or("");
            // Any extension is a format to Rails' router (`(.:format)` takes /[^\/.?]+/); only a known one names a MIME type.
            let found = last.rsplit_once('.').filter(|(base, ext)| !base.is_empty() && !ext.is_empty()).map(|(_, ext)| {
                (ext.to_string(), AXUM_DSL_FORMATS.iter().find(|(format, _)| *format == ext).map(|(_, mime)| *mime))
            });
            if let Some((format, mime)) = found {
                let stripped = &path[..path.len() - format.len() - 1];
                if !axum_dsl_format_routed(&path) && axum_dsl_format_routed(stripped) {
                    let query = match request.uri().query() {
                        Some(query) if !query.is_empty() => format!("{query}&format={format}"),
                        _ => format!("format={format}"),
                    };
                    if let Ok(uri) = format!("{stripped}?{query}").parse::<::axum::http::Uri>() {
                        *request.uri_mut() = uri;
                        if let Some(mime) = mime {
                            request.headers_mut().insert(::axum::http::header::ACCEPT, ::axum::http::HeaderValue::from_static(mime));
                        }
                    }
                }
            }
            next.run(request).await
        }
      RS
    end
  end
end
