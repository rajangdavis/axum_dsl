# frozen_string_literal: true

module AxumDsl
  # `opengraph_unfurl(url)`: Campfire's UnfurlLinksController#create, `Opengraph::Metadata.from_url(url)` answered as
  # `render json:` when it validates and nil (Rails' `head :no_content`) when it does not. The runtime follows
  # app/models/opengraph/*.rb and lib/restricted_http/private_network_guard.rb:
  # - the URL (or a tweet's, with its host swapped for fxtwitter.com) must be http(s) and resolve to a public address,
  #   which the request is pinned to (no proxy, no second lookup); file and media URLs are never fetched;
  # - at most 10 requests along redirects, each target absolute http(s) and public again; the document only from a 200
  #   whose Content-Type is text/html, at most 5 MB by Content-Length and by the bytes read;
  # - every `<meta>` whose `property` (else `name`) starts with "og:", that prefix removed wherever it occurs, a blank
  #   `content` skipped and the last of a key winning; title, url, image and description kept;
  # - the og url only when it is itself a valid location, else the URL asked for; the image only when a HEAD of it
  #   answers image/jpeg, png, gif or webp; title and description through `sanitize(strip_tags(...))`; valid when
  #   title, url and description are present;
  # - the JSON is the object's instance variables in the order Rails assigns them, then `context_for_validation` and
  #   `errors`, with ActiveSupport's HTML-entity escaping.
  # The address policy is surfguard's blocked ranges as this module lists them (loopback, private, link-local, shared,
  # documentation, benchmarking, multicast, reserved, unspecified, IPv6 unique-local, mapped and translated IPv4).
  module Opengraph
    module_function

    CALL = "opengraph_unfurl"

    def used?(ir) = ir["builtins"].to_a.include?(CALL)

    def items(ir) = used?(ir) ? RUNTIME.lines.map(&:chomp) + [""] : []

    # reqwest with rustls and the system's roots (rustls-native-certs reads SSL_CERT_FILE), and scraper for the DOM.
    def deps(ir)
      return "" unless used?(ir)

      "\nreqwest = { version = \"0.12\", default-features = false, features = [\"rustls-tls-native-roots\"] }\n#{AxumDsl::Sanitize::SCRAPER_DEP}"
    end

    RUNTIME = <<~'RS'
      const AXUM_DSL_OG_MAX_BODY: usize = 5 * 1024 * 1024;
      const AXUM_DSL_OG_MAX_REQUESTS: usize = 10;
      const AXUM_DSL_OG_TWITTER_HOSTS: [&str; 4] = ["twitter.com", "www.twitter.com", "x.com", "www.x.com"];
      const AXUM_DSL_OG_IMAGE_TYPES: [&str; 4] = ["image/jpeg", "image/png", "image/gif", "image/webp"];
      const AXUM_DSL_OG_MEDIA: [&str; 34] = [
          "zip", "tar", "tar.gz", "tar.bz2", "tar.xz", "gz", "bz2", "rar", "7z", "dmg", "exe", "msi", "pkg", "deb", "iso", "jpg",
          "jpeg", "png", "gif", "bmp", "mp4", "mov", "avi", "mkv", "wmv", "flv", "heic", "heif", "mp3", "wav", "ogg", "aac",
          "wma", "webm",
      ];
      const AXUM_DSL_OG_MORE_MEDIA: [&str; 3] = ["ogv", "mpg", "mpeg"];

      /// A URL as Ruby's URI.parse sees it, for the parts this needs: refused when it holds a space, a control or a
      /// non-ASCII character (InvalidURIError there), or when it is not http(s) with a host.
      struct AxumDslOgLocation {
          url: reqwest::Url,
          host: String,
          port: u16,
      }

      fn axum_dsl_og_parse_location(raw: &str) -> Option<AxumDslOgLocation> {
          if raw.is_empty() || raw.chars().any(|c| !c.is_ascii_graphic()) {
              return None;
          }
          let url = reqwest::Url::parse(raw).ok()?;
          if url.scheme() != "http" && url.scheme() != "https" {
              return None;
          }
          let host = url.host_str()?.trim_start_matches('[').trim_end_matches(']').to_ascii_lowercase();
          if host.is_empty() {
              return None;
          }
          let port = url.port_or_known_default()?;
          Some(AxumDslOgLocation { url, host, port })
      }

      /// Surfguard's blocked ranges: loopback, private, link-local, shared (CGNAT), documentation, benchmarking,
      /// multicast, reserved and unspecified addresses, IPv6 unique-local, and IPv4 addresses mapped or translated into IPv6.
      fn axum_dsl_og_blocked_address(ip: ::std::net::IpAddr) -> bool {
          match ip {
              ::std::net::IpAddr::V4(v4) => {
                  let [a, b, c, _] = v4.octets();
                  a == 0
                      || a == 10
                      || a == 127
                      || (a == 100 && (64..=127).contains(&b))
                      || (a == 169 && b == 254)
                      || (a == 172 && (16..=31).contains(&b))
                      || (a == 192 && b == 0 && (c == 0 || c == 2))
                      || (a == 192 && b == 88 && c == 99)
                      || (a == 192 && b == 168)
                      || (a == 198 && (b == 18 || b == 19))
                      || (a == 198 && b == 51 && c == 100)
                      || (a == 203 && b == 0 && c == 113)
                      || a >= 224
              }
              ::std::net::IpAddr::V6(v6) => {
                  if let Some(v4) = v6.to_ipv4_mapped() {
                      return axum_dsl_og_blocked_address(::std::net::IpAddr::V4(v4));
                  }
                  let s = v6.segments();
                  v6.is_unspecified()
                      || v6.is_loopback()
                      || (s[0] & 0xfe00) == 0xfc00 // unique local
                      || (s[0] & 0xffc0) == 0xfe80 // link local
                      || (s[0] & 0xff00) == 0xff00 // multicast
                      || (s[0] == 0x2001 && s[1] == 0x0db8) // documentation
                      || (s[0] == 0x0064 && s[1] == 0xff9b) // NAT64: an IPv4 address behind it
                      || (s[0] == 0x2002) // 6to4
                      || (s[0] == 0 && s[1] == 0 && s[2] == 0 && s[3] == 0 && s[4] == 0 && s[5] == 0) // IPv4-compatible
              }
          }
      }

      /// RestrictedHTTP::PrivateNetworkGuard.resolve: the host's first public address, None when it resolves to nothing
      /// public (or to nothing at all).
      async fn axum_dsl_og_resolve_public(host: &str, port: u16) -> Option<::std::net::SocketAddr> {
          if let Ok(ip) = host.parse::<::std::net::IpAddr>() {
              return (!axum_dsl_og_blocked_address(ip)).then(|| ::std::net::SocketAddr::new(ip, port));
          }
          let found = tokio::time::timeout(::std::time::Duration::from_secs(10), tokio::net::lookup_host((host, port))).await.ok()?.ok()?;
          found.into_iter().find(|a| !axum_dsl_og_blocked_address(a.ip()))
      }

      /// Opengraph::Location#valid?: an http(s) URL whose host resolves to a public address.
      async fn axum_dsl_og_valid_location(raw: &str) -> Option<(AxumDslOgLocation, ::std::net::SocketAddr)> {
          let loc = axum_dsl_og_parse_location(raw)?;
          let addr = axum_dsl_og_resolve_public(&loc.host, loc.port).await?;
          Some((loc, addr))
      }

      fn axum_dsl_og_client(loc: &AxumDslOgLocation, addr: ::std::net::SocketAddr) -> Option<reqwest::Client> {
          reqwest::Client::builder()
              .no_proxy()
              .redirect(reqwest::redirect::Policy::none())
              .resolve(&loc.host, addr)
              .connect_timeout(::std::time::Duration::from_secs(60))
              .read_timeout(::std::time::Duration::from_secs(60))
              .build()
              .ok()
      }

      /// Opengraph::Fetch#request: follow redirects (each target checked and pinned again) for at most 10 requests, and
      /// hand back the final response.
      async fn axum_dsl_og_request(mut loc: AxumDslOgLocation, mut addr: ::std::net::SocketAddr, head: bool) -> Option<reqwest::Response> {
          for _ in 0..AXUM_DSL_OG_MAX_REQUESTS {
              let http = axum_dsl_og_client(&loc, addr)?;
              let req = if head { http.head(loc.url.clone()) } else { http.get(loc.url.clone()) };
              let res = req.header("Accept", "*/*").header("User-Agent", "Ruby").send().await.ok()?;
              if res.status().is_redirection() {
                  let target = res.headers().get(reqwest::header::LOCATION)?.to_str().ok()?.to_string();
                  let next = axum_dsl_og_parse_location(&target)?; // a relative or non-http Location is RedirectDeniedError
                  addr = axum_dsl_og_resolve_public(&next.host, next.port).await?;
                  loc = next;
                  continue;
              }
              return Some(res);
          }
          None // TooManyRedirectsError
      }

      /// Net::HTTP's `content_type`: the media type alone, lowercased.
      fn axum_dsl_og_media_type(res: &reqwest::Response) -> Option<String> {
          let v = res.headers().get(reqwest::header::CONTENT_TYPE)?.to_str().ok()?;
          Some(v.split(';').next().unwrap_or("").trim().to_ascii_lowercase())
      }

      async fn axum_dsl_og_fetch_document(loc: AxumDslOgLocation, addr: ::std::net::SocketAddr) -> Option<String> {
          let mut res = axum_dsl_og_request(loc, addr, false).await?;
          if res.status() != reqwest::StatusCode::OK || axum_dsl_og_media_type(&res).as_deref() != Some("text/html") {
              return None;
          }
          let declared = res
              .headers()
              .get(reqwest::header::CONTENT_LENGTH)
              .and_then(|v| v.to_str().ok())
              .and_then(|v| v.trim().parse::<u64>().ok())
              .unwrap_or(0);
          if declared > AXUM_DSL_OG_MAX_BODY as u64 {
              return None;
          }
          let mut body: Vec<u8> = Vec::new();
          while let Some(chunk) = res.chunk().await.ok()? {
              if body.len() + chunk.len() > AXUM_DSL_OG_MAX_BODY {
                  return None;
              }
              body.extend_from_slice(&chunk);
          }
          Some(String::from_utf8_lossy(&body).into_owned())
      }

      /// FILES_AND_MEDIA_URL_REGEX: `\bhttps?://\S+\.(ext)\b` anywhere in the URL.
      fn axum_dsl_og_media_url(raw: &str) -> bool {
          // The regex has no /i: the scheme and the extension match as written.
          let Some(start) = raw.find("http://").or_else(|| raw.find("https://")) else { return false };
          let rest = &raw[start..];
          let rest = rest.split(char::is_whitespace).next().unwrap_or("");
          let after_scheme = rest.find("://").map(|i| &rest[i + 3..]).unwrap_or("");
          for (i, _) in after_scheme.match_indices('.') {
              if i == 0 {
                  continue;
              }
              let tail = &after_scheme[i + 1..];
              for ext in AXUM_DSL_OG_MEDIA.iter().chain(AXUM_DSL_OG_MORE_MEDIA.iter()) {
                  if tail.len() >= ext.len() && tail[..ext.len()].eq(*ext) {
                      let next = tail[ext.len()..].chars().next();
                      if next.map_or(true, |c| !(c.is_alphanumeric() || c == '_')) {
                          return true;
                      }
                  }
              }
          }
          false
      }

      /// Fetching#tweet_url? and replace_twitter_domain_for_opengraph_support.
      fn axum_dsl_og_fetch_url_for(raw: &str) -> String {
          if let Some(mut loc) = axum_dsl_og_parse_location(raw) {
              let path = loc.url.path().to_string();
              if AXUM_DSL_OG_TWITTER_HOSTS.contains(&loc.host.as_str()) && !path.is_empty() && path != "/" && loc.url.set_host(Some("fxtwitter.com")).is_ok() {
                  return loc.url.to_string();
              }
          }
          raw.to_string()
      }

      /// Opengraph::Document#opengraph_attributes, as (key, content) in Hash order: a key keeps the position of its first
      /// tag and the content of its last.
      fn axum_dsl_og_opengraph_attributes(html: &str) -> Vec<(String, String)> {
          let doc = scraper::Html::parse_document(html);
          let Ok(meta) = scraper::Selector::parse("meta") else { return vec![] };
          // Document#sanitize_content: without a charset in a <meta> (Nokogiri's meta_encoding), the content is re-encoded
          // from binary to UTF-8 dropping what does not convert, i.e. every non-ASCII character.
          let declared = doc.select(&meta).any(|t| {
              let el = t.value();
              el.attr("charset").is_some_and(|c| !c.trim().is_empty())
                  || (el.attr("http-equiv").is_some_and(|h| h.eq_ignore_ascii_case("content-type"))
                      && el.attr("content").is_some_and(|c| c.to_ascii_lowercase().contains("charset=")))
          });
          let mut out: Vec<(String, String)> = Vec::new();
          for tag in doc.select(&meta) {
              let el = tag.value();
              let key_attr = if el.attr("property").is_some() { el.attr("property") } else { el.attr("name") };
              let (Some(name), Some(content)) = (key_attr, el.attr("content")) else { continue };
              // The XPath's `starts-with(@property, "og:") or starts-with(@name, "og:")` picks the tag; the key is then
              // the property when there is one.
              let picked = el.attr("property").is_some_and(|p| p.starts_with("og:")) || el.attr("name").is_some_and(|n| n.starts_with("og:"));
              if !picked || content.trim().is_empty() {
                  continue;
              }
              let key = name.replace("og:", "");
              let content: String = if declared { content.to_string() } else { content.chars().filter(char::is_ascii).collect() };
              match out.iter_mut().find(|(k, _)| *k == key) {
                  Some(slot) => slot.1 = content.to_string(),
                  None => out.push((key, content.to_string())),
              }
          }
          // Hash#slice(:title, :url, :image, :description): in that order.
          ["title", "url", "image", "description"]
              .iter()
              .filter_map(|k| out.iter().find(|(key, _)| key == k).cloned())
              .collect()
      }

      /// `sanitize(axum_dsl_og_strip_tags(s))`: the text of every node, with &, < and > escaped and a no-break space written &nbsp;.
      fn axum_dsl_og_strip_tags(s: &str) -> String {
          let frag = scraper::Html::parse_fragment(s);
          let text: String = frag.root_element().text().collect();
          let mut out = String::with_capacity(text.len());
          for c in text.chars() {
              match c {
                  '&' => out.push_str("&amp;"),
                  '<' => out.push_str("&lt;"),
                  '>' => out.push_str("&gt;"),
                  '\u{a0}' => out.push_str("&nbsp;"),
                  other => out.push(other),
              }
          }
          out
      }

      /// ActiveSupport's JSON string: escape_html_entities_in_json (<, >, & as \u003c, \u003e, \u0026) and U+2028/2029.
      fn axum_dsl_og_json_string(s: &str) -> String {
          let base = serde_json::to_string(s).unwrap_or_else(|_| "\"\"".to_string());
          base.replace('<', "\\u003c").replace('>', "\\u003e").replace('&', "\\u0026").replace('\u{2028}', "\\u2028").replace('\u{2029}', "\\u2029")
      }

      fn axum_dsl_og_blank(s: &str) -> bool {
          s.chars().all(char::is_whitespace)
      }

      async fn axum_dsl_opengraph_unfurl(url: &str) -> Option<String> {
          let target = axum_dsl_og_fetch_url_for(url);
          let html = match axum_dsl_og_valid_location(&target).await {
              Some((loc, addr)) if !axum_dsl_og_media_url(&target) => axum_dsl_og_fetch_document(loc, addr).await.unwrap_or_default(),
              _ => String::new(),
          };
          let attrs = axum_dsl_og_opengraph_attributes(&html);
          let get = |k: &str| attrs.iter().find(|(key, _)| key == k).map(|(_, v)| v.clone());
          // valid_canonical_url(attributes[:url], url)
          let og_url = get("url");
          let canonical = match &og_url {
              Some(u) if axum_dsl_og_valid_location(u).await.is_some() => u.clone(),
              _ => url.to_string(),
          };
          // valid_image_content_type(attributes[:image])
          let image = match get("image") {
              Some(img) if !axum_dsl_og_blank(&img) => match axum_dsl_og_valid_location(&img).await {
                  Some((loc, addr)) => match axum_dsl_og_request(loc, addr, true).await {
                      Some(res) => {
                          let ct = res.headers().get(reqwest::header::CONTENT_TYPE).and_then(|v| v.to_str().ok()).map(|v| v.to_ascii_lowercase());
                          ct.filter(|t| AXUM_DSL_OG_IMAGE_TYPES.contains(&t.as_str())).map(|_| img)
                      }
                      None => None,
                  },
                  None => None,
              },
              _ => None,
          };
          let title = axum_dsl_og_strip_tags(&get("title").unwrap_or_default());
          let description = axum_dsl_og_strip_tags(&get("description").unwrap_or_default());
          if axum_dsl_og_blank(&title) || axum_dsl_og_blank(&canonical) || axum_dsl_og_blank(&description) {
              return None;
          }
          if let Some(img) = &image {
              axum_dsl_og_valid_location(img).await?;
          }
          // Opengraph::Metadata.new(attributes.merge(url:, image:)): the document's keys in their order, then url and image
          // when the document had none; a key absent from the document but merged in is written even when nil.
          let mut keys: Vec<&str> = attrs.iter().map(|(k, _)| k.as_str()).collect();
          for k in ["url", "image"] {
              if !keys.contains(&k) {
                  keys.push(k);
              }
          }
          let mut parts: Vec<String> = Vec::new();
          for k in keys {
              let value = match k {
                  "title" => axum_dsl_og_json_string(&title),
                  "description" => axum_dsl_og_json_string(&description),
                  "url" => axum_dsl_og_json_string(&canonical),
                  _ => image.as_deref().map(axum_dsl_og_json_string).unwrap_or_else(|| "null".to_string()),
              };
              parts.push(format!("\"{k}\":{value}"));
          }
          parts.push("\"context_for_validation\":{\"context\":null}".to_string());
          parts.push("\"errors\":{}".to_string());
          Some(format!("{{{}}}", parts.join(",")))
      }
    RS
  end
end
