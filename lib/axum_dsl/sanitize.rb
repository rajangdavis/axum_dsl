# frozen_string_literal: true

module AxumDsl
  # The compiler's own HTML sanitiser for a view's `{{ name|sanitize }}` (docs/views.md): an Action Text body
  # carries markup, so escaping it would show the tags and `|raw` would trust them. Two forms:
  #
  # * `{{ name|sanitize }}` is ammonia's default allowlist -- its tags, its href/src attributes and its URL
  #   schemes -- with generic `class` allowed because Action Text/Trix uses classes.
  # * `{{ name|sanitize :profile }}` names a `sanitizer :profile, tags: [...], attributes: [...]` declared at the
  #   top of the file: exactly those tags and those attributes (on any tag, as Rails' safe-list sanitizer takes
  #   them), the URL checks ammonia applies to every href/src, no `rel` added to links unless asked, and an
  #   optional auto_link pass (`autolink_target:`). A tag that is not listed is dropped and its children kept,
  #   which is how `figure.lexxy-content__table-wrapper` unwraps when `figure` is not listed.
  #
  # The helpers and the dependency are emitted only into a crate whose views sanitise a value, as Sessions'
  # pieces are.
  module Sanitize
    # One pass over the HTML: ammonia's default builder, with class kept on any element. The call site is
    # path-qualified (`axum_dsl_sanitize`), so it needs no `use`.
    HELPER = <<~'RS'
      // One builder, and the output memoized because sanitize is pure: this runs once per message body on every
      // render, and skipping it made message pages 41-69% faster (WAVE-PLAN Track AP, AP4 measured).
      static AXUM_DSL_SANITIZER: std::sync::LazyLock<::ammonia::Builder<'static>> = std::sync::LazyLock::new(|| {
          let mut builder = ::ammonia::Builder::default();
          builder.add_generic_attributes(&["class"]);
          builder
      });
      static AXUM_DSL_SANITIZED: std::sync::LazyLock<std::sync::RwLock<(std::collections::HashMap<String, String>, usize)>> =
          std::sync::LazyLock::new(|| std::sync::RwLock::new((std::collections::HashMap::new(), 0)));
      const AXUM_DSL_SANITIZED_MAX: usize = 8 << 20;

      fn axum_dsl_sanitize_into(buf: &mut String, html: &str) {
          let cacheable = html.len() <= 64 << 10;
          if cacheable {
              let cache = AXUM_DSL_SANITIZED.read().unwrap_or_else(|p| p.into_inner());
              if let Some(out) = cache.0.get(html) {
                  buf.push_str(out);
                  return;
              }
          }
          let out = AXUM_DSL_SANITIZER.clean(html).to_string();
          buf.push_str(&out);
          if cacheable {
              let mut cache = AXUM_DSL_SANITIZED.write().unwrap_or_else(|p| p.into_inner());
              let (map, bytes) = &mut *cache;
              if !map.contains_key(html) {
                  let size = html.len() + out.len();
                  if *bytes + size > AXUM_DSL_SANITIZED_MAX {
                      map.clear();
                      *bytes = 0;
                  }
                  map.insert(html.to_owned(), out);
                  *bytes += size;
              }
          }
      }
    RS

    # What every declared `sanitizer` shares: the builder type, its memo and the auto_link pass.
    PROFILE_RUNTIME = <<~'RS'
      // A user an `attachments:` mention is drawn from: the fields of `users/_mention` (a view passes them with `mentions:`).
      #[allow(dead_code)]
      struct AxumDslMention {
          id: i64,
          name: String,
          title: String,
          version: String,
      }

      // A declared `sanitizer :name` (docs/views.md): its own ammonia builder over exactly the declared tags and
      // generic attributes, and the output memoized by the full input as the default sanitiser's is.
      struct AxumDslSanitizer {
          builder: ::ammonia::Builder<'static>,
          autolink: Option<&'static str>,
          cache: std::sync::RwLock<(std::collections::HashMap<String, String>, usize)>,
          // `attachments:` draws the <action-text-attachment>s of a body for a request host; `sounds:` draws a body
          // that is only `/play NAME`. Each is a function the compiler wrote from the sanitizer's partials.
          attachments: Option<fn(&str, &str, &[AxumDslMention]) -> Option<String>>,
          sounds: Option<fn(&str) -> Option<String>>,
      }

      impl AxumDslSanitizer {
          fn new(tags: &[&'static str], attributes: &[&'static str], link_rel: bool, autolink: Option<&'static str>) -> Self {
              let mut builder = ::ammonia::Builder::default();
              builder.tags(tags.iter().copied().collect());
              builder.tag_attributes(std::collections::HashMap::new());
              builder.generic_attributes(attributes.iter().copied().collect());
              if !link_rel {
                  builder.link_rel(None);
              }
              AxumDslSanitizer {
                  builder,
                  autolink,
                  cache: std::sync::RwLock::new((std::collections::HashMap::new(), 0)),
                  attachments: None,
                  sounds: None,
              }
          }

          #[allow(dead_code)]
          fn with_attachments(mut self, draw: fn(&str, &str, &[AxumDslMention]) -> Option<String>) -> Self {
              self.attachments = Some(draw);
              self
          }

          #[allow(dead_code)]
          fn with_sounds(mut self, draw: fn(&str) -> Option<String>) -> Self {
              self.sounds = Some(draw);
              self
          }

          fn clean_into(&self, buf: &mut String, html: &str, host: &str, mentions: &[AxumDslMention]) {
              // A body holding an attachment is drawn for the request host, so it is not memoized by its text alone.
              let drawn = self.attachments.is_some() && html.contains("<action-text-attachment");
              let cacheable = html.len() <= 64 << 10 && !drawn;
              if cacheable {
                  let cache = self.cache.read().unwrap_or_else(|p| p.into_inner());
                  if let Some(out) = cache.0.get(html) {
                      buf.push_str(out);
                      return;
                  }
              }
              let out = match self.sounds.and_then(|sound| sound(html)) {
                  Some(sound) => sound,
                  None => {
                      let rewritten = self.attachments.filter(|_| drawn).and_then(|draw| draw(html, host, mentions));
                      let mut out = self.builder.clean(rewritten.as_deref().unwrap_or(html)).to_string();
                      if let Some(target) = self.autolink {
                          out = axum_dsl_autolink(&out, target);
                      }
                      out
                  }
              };
              buf.push_str(&out);
              if cacheable {
                  let mut cache = self.cache.write().unwrap_or_else(|p| p.into_inner());
                  let (map, bytes) = &mut *cache;
                  if !map.contains_key(html) {
                      let size = html.len() + out.len();
                      if *bytes + size > AXUM_DSL_PROFILE_MAX {
                          map.clear();
                          *bytes = 0;
                      }
                      map.insert(html.to_owned(), out);
                      *bytes += size;
                  }
              }
          }
      }

      // auto_link (rails_autolink, `link: :all`) over cleaned HTML: e-mail addresses, then URLs, each skipped
      // inside a tag or an open <a>, with the trailing punctuation and unbalanced brackets left outside the link.
      const AXUM_DSL_PROFILE_MAX: usize = 8 << 20;
      const AXUM_DSL_AUTOLINK_SCHEMES: [&str; 24] = [
          "ed2k", "ftp", "http", "https", "irc", "mailto", "news", "gopher", "nntp", "telnet", "webcal", "xmpp",
          "callto", "feed", "svn", "urn", "aim", "rsync", "tag", "ssh", "sftp", "rtsp", "afs", "file",
      ];

      fn axum_dsl_autolink(html: &str, target: &str) -> String {
          axum_dsl_autolink_urls(&axum_dsl_autolink_emails(html, target), target)
      }

      // rails_autolink's auto_linked?: the match sits inside a tag, or inside an <a> that is still open.
      fn axum_dsl_autolinked(left: &str, right: &str) -> bool {
          let after_gt = left.rfind('>').map_or(0, |at| at + 1);
          let tail = &left[after_gt..];
          let inner = tail.char_indices().last().map_or("", |(k, _)| &tail[..k]);
          if inner.contains('<') && right.contains('>') {
              return true;
          }
          let lower = left.to_ascii_lowercase();
          let mut end = lower.len();
          while let Some(at) = lower[..end].rfind("<a") {
              end = at;
              let after = &lower[at + 2..];
              if after.chars().next().is_some_and(|c| c.is_ascii_alphanumeric() || c == '_') {
                  continue;
              }
              let line = after.split('\n').next().unwrap_or("");
              if let Some(gt) = line.find('>') {
                  return !after[gt + 1..].contains("</a>");
              }
          }
          false
      }

      fn axum_dsl_autolink_urls(html: &str, target: &str) -> String {
          let bytes = html.as_bytes();
          let mut out = String::with_capacity(html.len() + 64);
          let (mut i, mut copied) = (0, 0);
          while i < bytes.len() {
              if !bytes[i].is_ascii_alphabetic() || !html.is_char_boundary(i) {
                  i += 1;
                  continue;
              }
              let rest = &html[i..];
              let lower: String = rest.bytes().take(12).map(|b| b.to_ascii_lowercase() as char).collect();
              let prefix = if lower.starts_with("www.") {
                  Some((4, false))
              } else {
                  AXUM_DSL_AUTOLINK_SCHEMES
                      .iter()
                      .filter(|s| lower.starts_with(*s) && rest[s.len()..].starts_with("://"))
                      .map(|s| (s.len() + 3, true))
                      .next()
              };
              let Some((plen, scheme)) = prefix else {
                  i += 1;
                  continue;
              };
              let body = &rest[plen..];
              let body_len = body
                  .find(|c: char| c.is_ascii_whitespace() || c == '\u{b}' || c == '<' || c == '\u{a0}' || c == '"')
                  .unwrap_or(body.len());
              if body_len == 0 {
                  i += 1;
                  continue;
              }
              let end = i + plen + body_len;
              out.push_str(&html[copied..i]);
              copied = end;
              if axum_dsl_autolinked(&html[..i], &html[end..]) {
                  out.push_str(&html[i..end]);
                  i = end;
                  continue;
              }
              let mut href = html[i..end].to_string();
              let mut punctuation: Vec<char> = Vec::new();
              while let Some(c) = href.chars().last() {
                  if c.is_alphanumeric() || matches!(c, '_' | '/' | '-' | '=' | '&') {
                      break;
                  }
                  href.pop();
                  punctuation.push(c);
                  let open = match c {
                      ']' => Some('['),
                      ')' => Some('('),
                      '}' => Some('{'),
                      _ => None,
                  };
                  if let Some(open) = open {
                      if href.matches(open).count() > href.matches(c).count() {
                          href.push(punctuation.pop().unwrap_or(c));
                          break;
                      }
                  }
              }
              let trailing_gt = if href.ends_with("&gt;") {
                  href.truncate(href.len() - 4);
                  "&gt;"
              } else {
                  ""
              };
              let link = if scheme { href.clone() } else { format!("http://{href}") };
              out.push_str(&format!("<a target=\"{target}\" href=\"{link}\">{href}</a>"));
              out.extend(punctuation.iter().rev());
              out.push_str(trailing_gt);
              i = end;
          }
          out.push_str(&html[copied..]);
          out
      }

      fn axum_dsl_autolink_emails(html: &str, target: &str) -> String {
          let local = |c: char| c.is_ascii_alphanumeric() || "_.!#$%&'*/=?^`{|}~+-".contains(c);
          let first = |c: char| c.is_ascii_alphanumeric() || "_.!#$%+-".contains(c);
          let label = |c: char| c.is_ascii_alphanumeric() || c == '_' || c == '-';
          let mut out = String::with_capacity(html.len());
          let mut copied = 0;
          let mut search = 0;
          while let Some(found) = html[search..].find('@') {
              let at = search + found;
              search = at + 1;
              let mut start = at;
              for (k, c) in html[copied..at].char_indices().rev() {
                  if !local(c) {
                      break;
                  }
                  start = copied + k;
              }
              while start < at && !first(html[start..].chars().next().unwrap_or(' ')) {
                  start += html[start..].chars().next().map_or(1, |c| c.len_utf8());
              }
              if start == at {
                  continue;
              }
              let domain = &html[at + 1..];
              let mut len = 0;
              let mut labels = 0;
              loop {
                  let n = domain[len..].chars().take_while(|c| label(*c)).map(char::len_utf8).sum::<usize>();
                  if n == 0 {
                      break;
                  }
                  len += n;
                  labels += 1;
                  if domain[len..].starts_with('.') && domain[len + 1..].chars().next().is_some_and(label) {
                      len += 1;
                  } else {
                      break;
                  }
              }
              if labels < 2 {
                  continue;
              }
              let end = at + 1 + len;
              search = end;
              if axum_dsl_autolinked(&html[..start], &html[end..]) {
                  continue;
              }
              let address = html[start..end].replace('&', "&amp;").replace('\'', "&#39;");
              out.push_str(&html[copied..start]);
              out.push_str(&format!("<a target=\"{target}\" href=\"mailto:{address}\">{address}</a>"));
              copied = end;
          }
          out.push_str(&html[copied..]);
          out
      }
    RS

    # Ruby's String#strip (NUL and ASCII whitespace), which both `sounds:` and `attachments:` read text through.
    STRIP_RUNTIME = <<~'RS'
      fn axum_dsl_ruby_strip(text: &str) -> &str {
          text.trim_matches(|c: char| c == '\0' || c.is_ascii_whitespace() || c == '\u{b}')
      }
    RS

    # What `sounds:` shares: a body's plain text (Action Text's to_plain_text, as far as a command or a lone link needs)
    # and `\A/play (\w+)\z` over it, as Message#sound matches. Written once for every sanitizer that lists sounds.
    SOUND_RUNTIME = <<~'RS'
      // The plain text of an HTML string: its tags removed, its entities read, stripped.
      fn axum_dsl_plain_text(html: &str) -> String {
          let cleaned = ::ammonia::Builder::empty().clean(html).to_string();
          let text = cleaned
              .replace("&nbsp;", "\u{a0}")
              .replace("&lt;", "<")
              .replace("&gt;", ">")
              .replace("&quot;", "\"")
              .replace("&#39;", "'")
              .replace("&amp;", "&");
          axum_dsl_ruby_strip(&text).to_string()
      }

      // `/play NAME` and nothing else, with NAME made of letters, digits and _.
      fn axum_dsl_play_name(html: &str) -> Option<String> {
          if !html.contains("/play ") {
              return None;
          }
          let text = axum_dsl_plain_text(html);
          let name = text.strip_prefix("/play ")?;
          (!name.is_empty() && name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_')).then(|| name.to_string())
      }
    RS

    # The attachable sgid of an Action Text attachment (`user.attachable_sgid`), read without checking its signature:
    # lib/rails_ext/action_text_attachables.rb tolerates a Rails 7 Marshal-era one for users, and the GlobalID inside
    # names the model and the id. Written for a sanitizer that draws mentions, and for a query that calls the SQL
    # function `action_text_attachable_ids(html, 'User')` (the User ids of a body's attachments, as a JSON array).
    ATTACHABLE_RUNTIME = <<~'RS'
      #[allow(dead_code)]
      fn axum_dsl_attachable_gid(sgid: &str) -> Option<(String, i64)> {
          use ::base64::Engine;
          let decode = |text: &str| -> Option<String> {
              let text = text.trim_end_matches('=');
              let bytes = ::base64::engine::general_purpose::STANDARD_NO_PAD
                  .decode(text)
                  .or_else(|_| ::base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(text))
                  .ok()?;
              Some(String::from_utf8_lossy(&bytes).into_owned())
          };
          let find = |text: &str| -> Option<(String, i64)> {
              let rest = &text[text.find("gid://")? + 6..];
              let (_, rest) = rest.split_once('/')?;
              let (model, rest) = rest.split_once('/')?;
              let digits: String = rest.chars().take_while(char::is_ascii_digit).collect();
              Some((model.to_string(), digits.parse().ok()?))
          };
          let envelope = decode(sgid.split("--").next()?)?.replace("\\/", "/");
          if let Some(found) = find(&envelope) {
              return Some(found);
          }
          // A Rails 7 MessageVerifier envelope: "message" is the base64 of the Marshal dump of the GlobalID string.
          let inner = envelope.split_once("\"message\":\"")?.1.split('"').next()?;
          find(&decode(inner)?)
      }

      #[allow(dead_code)]
      fn axum_dsl_attachable_ids_json(html: &str, model: &str) -> String {
          let mut ids: Vec<i64> = Vec::new();
          let mut rest = html;
          while let Some(at) = rest.find("<action-text-attachment") {
              rest = &rest[at + 23..];
              let tag = &rest[..rest.find('>').unwrap_or(rest.len())];
              let sgid = tag.split_once("sgid=\"").and_then(|(_, value)| value.split('"').next());
              if let Some((found, id)) = sgid.and_then(axum_dsl_attachable_gid) {
                  if found == model && !ids.contains(&id) {
                      ids.push(id);
                  }
              }
          }
          format!("[{}]", ids.iter().map(i64::to_string).collect::<Vec<_>>().join(","))
      }
    RS

    # ActionText::PlainTextConversion, shared by `attachments:` (the solo-link test) and the `plain_text(html)` body call.
    RAILS_PLAIN_TEXT = <<~'RS'
      // ActionText::PlainTextConversion over the children of a node, with an attachment drawn as the empty text
      // an opengraph embed has: paragraphs end in a blank line, a div and a br in a newline, and the whitespace
      // between two nodes stays, so `<p>link</p> <embed>` is not just the link.
      fn axum_dsl_rails_plain_text(element: ::scraper::ElementRef) -> String {
          let chomp = |text: String| text.trim_end_matches(['\n', '\r']).to_string();
          let mut out = String::new();
          for child in element.children() {
              if let Some(child) = ::scraper::ElementRef::wrap(child) {
                  match child.value().name() {
                      "action-text-attachment" => {}
                      "p" | "h1" => out.push_str(&format!("{}\n\n", chomp(axum_dsl_rails_plain_text(child)))),
                      "div" => out.push_str(&format!("{}\n", chomp(axum_dsl_rails_plain_text(child)))),
                      "br" => out.push('\n'),
                      _ => out.push_str(&axum_dsl_rails_plain_text(child)),
                  }
              } else if let Some(text) = child.value().as_text() {
                  let text: &str = text;
                  out.push_str(text.trim_end_matches(['\n', '\r']));
              }
          }
          out
      }

    RS

    # `plain_text(html)`: ActionText::Content#to_plain_text, the conversion above with the trailing newlines removed.
    PLAIN_TEXT_CALL = <<~'RS'
      fn axum_dsl_action_text_plain_text(html: &str) -> String {
          let fragment = ::scraper::Html::parse_fragment(html);
          axum_dsl_rails_plain_text(fragment.root_element()).trim_end_matches(['\n', '\r']).to_string()
      }
    RS

    # `action_text_html(html)`: the HTML Action Text stores for a body it is given (ActionText::Content.new: the text
    # stripped as Ruby's strip does, parsed as an HTML5 fragment in a body context -- Nokogiri::HTML5, gumbo -- and
    # serialized back): `&` becomes `&amp;`, CRLF becomes LF, unclosed tags close. html5ever implements the same parsing
    # and fragment serialization algorithms.
    ACTION_TEXT_HTML_CALL = <<~'RS'
      fn axum_dsl_action_text_html(html: &str) -> String {
          let stripped = html.trim_matches(|c: char| matches!(c, '\0' | ' ' | '\t' | '\n' | '\x0b' | '\x0c' | '\r'));
          ::scraper::Html::parse_fragment(stripped).root_element().inner_html()
      }
    RS

    # What `attachments:` shares: an Action Text opengraph embed read from an <action-text-attachment> (OpengraphEmbed
    # in once-campfire's lib/rails_ext), the web_url rules that keep a preview off this host, and the rewrite of a body
    # that draws each embed and applies RemoveSoloUnfurledLinkText. The markup of an embed is the sanitizer's partial.
    ATTACHMENT_RUNTIME = <<~'RS' + RAILS_PLAIN_TEXT + <<~'RS'
      struct AxumDslOpengraph {
          href: Option<String>,
          url: Option<String>,
          filename: Option<String>,
          description: Option<String>,
      }

      const AXUM_DSL_OPENGRAPH: &str = "application/vnd.actiontext.opengraph-embed";
      const AXUM_DSL_MENTION: &str = "application/vnd.campfire.mention";

      // An <action-text-attachment> a body draws: a link preview, or a mention of a user (the id its sgid names).
      enum AxumDslAttachment {
          Opengraph(AxumDslOpengraph),
          Mention(Option<i64>),
      }
      const AXUM_DSL_TWITTER_AVATAR: &str = "https://pbs.twimg.com/profile_images";
      const AXUM_DSL_VOID_TAGS: [&str; 14] =
          ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"];

      // A preview points at an absolute http or https URL on a named host that is not this one: no `%` in the host,
      // a dot, a last label with a letter that is not hexadecimal. Anything else is dropped (web_url).
      fn axum_dsl_web_url(value: Option<&str>, request_host: &str) -> Option<String> {
          let value = value?;
          if value.trim().is_empty() || !value.bytes().all(|b| b.is_ascii_graphic()) || value.bytes().any(|b| b"<>\"\\^`{|}".contains(&b)) {
              return None;
          }
          let bytes = value.as_bytes();
          for (at, &b) in bytes.iter().enumerate() {
              let hex = |k: usize| bytes.get(k).is_some_and(|d| d.is_ascii_hexdigit());
              if b == b'%' && !(hex(at + 1) && hex(at + 2)) {
                  return None;
              }
          }
          let (scheme, rest) = value.split_once(':')?;
          if !(scheme.eq_ignore_ascii_case("http") || scheme.eq_ignore_ascii_case("https")) {
              return None;
          }
          let authority = rest.strip_prefix("//")?.split(['/', '?', '#']).next().unwrap_or("");
          let host_port = authority.rsplit('@').next().unwrap_or("");
          if host_port.starts_with('[') {
              return None;
          }
          let host = host_port.split(':').next().unwrap_or("");
          let last = host.split('.').filter(|label| !label.is_empty()).last()?;
          let named = !host.is_empty()
              && !host.contains('%')
              && host.contains('.')
              && last.chars().any(|c| c.is_ascii_alphabetic())
              && !last.to_ascii_lowercase().starts_with("0x");
          let canonical = |h: &str| h.to_ascii_lowercase().strip_suffix('.').map(str::to_string).unwrap_or_else(|| h.to_ascii_lowercase());
          (named && canonical(host) != canonical(request_host)).then(|| value.to_string())
      }

      // The host of the request, from the host or the base URL a view names: no scheme, no port.
      fn axum_dsl_request_host(base: &str) -> &str {
          let rest = base.split_once("://").map_or(base, |(_, rest)| rest);
          let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
          authority.rsplit('@').next().unwrap_or("").split(':').next().unwrap_or("")
      }

      fn axum_dsl_element_text(element: ::scraper::ElementRef) -> String {
          axum_dsl_ruby_strip(&element.text().collect::<String>()).to_string()
      }

      // Trix wrote the details as attributes of the node; Lexxy wrote them as markup in `content`.
      fn axum_dsl_opengraph(element: ::scraper::ElementRef, host: &str) -> AxumDslOpengraph {
          let attr = |name: &str| element.value().attr(name);
          if attr("filename").is_some_and(|f| !f.trim().is_empty()) {
              return AxumDslOpengraph {
                  href: axum_dsl_web_url(attr("href"), host),
                  url: axum_dsl_web_url(attr("url"), host),
                  filename: attr("filename").map(str::to_string),
                  description: attr("caption").map(str::to_string),
              };
          }
          let fragment = ::scraper::Html::parse_fragment(attr("content").unwrap_or(""));
          let find = |css: &str| fragment.select(&::scraper::Selector::parse(css).expect("selector")).next();
          let title = find(".og-embed__title");
          let link = title.and_then(|t| t.select(&::scraper::Selector::parse("a").expect("selector")).next());
          AxumDslOpengraph {
              href: axum_dsl_web_url(link.and_then(|l| l.value().attr("href")), host),
              url: axum_dsl_web_url(find(".og-embed__image img").and_then(|i| i.value().attr("src")), host),
              filename: link.or(title).map(axum_dsl_element_text),
              description: find(".og-embed__description").map(axum_dsl_element_text),
          }
      }

      // ActionView's truncate(text, length:, omission: "…").
      fn axum_dsl_truncate(text: &str, length: usize) -> String {
          if text.chars().count() <= length {
              return text.to_string();
          }
          let kept: String = text.chars().take(length - 1).collect();
          format!("{kept}…")
      }

      // The embed through the sanitizer's partial, whose arguments are SANITIZER_PARTIALS["attachment"].
      fn axum_dsl_draw_opengraph(draw: fn(&str, &str, &str, &str, bool, bool, bool) -> String, embed: &AxumDslOpengraph) -> String {
          let href = embed.href.as_deref().unwrap_or("");
          let title = match &embed.filename {
              Some(filename) => axum_dsl_truncate(filename, 280),
              None => href.to_string(),
          };
          let description = axum_dsl_truncate(embed.description.as_deref().unwrap_or(""), 560);
          let image = embed.url.as_deref().unwrap_or("");
          draw(href, &title, &description, image, image.starts_with(AXUM_DSL_TWITTER_AVATAR), embed.href.is_some(), embed.url.is_some())
      }

      fn axum_dsl_is_embed(element: ::scraper::ElementRef) -> bool {
          element.value().name() == "action-text-attachment"
              && element.value().attr("content-type").is_some_and(|t| t.contains(AXUM_DSL_OPENGRAPH) || t.contains(AXUM_DSL_MENTION))
      }

      fn axum_dsl_find_embeds(element: ::scraper::ElementRef, host: &str, found: &mut Vec<AxumDslAttachment>) {
          for child in element.children() {
              if let Some(child) = ::scraper::ElementRef::wrap(child) {
                  if axum_dsl_is_embed(child) {
                      if child.value().attr("content-type").is_some_and(|t| t.contains(AXUM_DSL_MENTION)) {
                          // lib/rails_ext/action_text_attachables.rb: a mention names a User by its sgid.
                          let user = child.value().attr("sgid").and_then(axum_dsl_attachable_gid).filter(|(model, _)| model == "User");
                          found.push(AxumDslAttachment::Mention(user.map(|(_, id)| id)));
                      } else {
                          found.push(AxumDslAttachment::Opengraph(axum_dsl_opengraph(child, host)));
                      }
                  } else {
                      axum_dsl_find_embeds(child, host, found);
                  }
              }
          }
      }

      fn axum_dsl_has_attachment(element: ::scraper::ElementRef) -> bool {
          element.descendants().filter_map(::scraper::ElementRef::wrap).any(|e| e.value().name() == "action-text-attachment")
      }

      fn axum_dsl_has_div(element: ::scraper::ElementRef) -> bool {
          element.descendants().filter_map(::scraper::ElementRef::wrap).any(|e| e.value().name() == "div")
      }

    RS
      // ContentFilters::RemoveSoloUnfurledLinkText's normalize_tweet_url: x.com is twitter.com and a tweet's query goes.
      fn axum_dsl_normalize_tweet_url(url: &str) -> String {
          if url.trim().is_empty() || url.chars().any(char::is_whitespace) || !(url.contains("x.com") || url.contains("twitter.com")) {
              return url.to_string();
          }
          let (rest, fragment) = match url.split_once('#') {
              Some((rest, fragment)) => (rest, format!("#{fragment}")),
              None => (url, String::new()),
          };
          let rest = rest.split_once('?').map_or(rest, |(rest, _)| rest);
          let Some((scheme, after)) = rest.split_once("://") else {
              return format!("{rest}{fragment}");
          };
          let (authority, path) = match after.find('/') {
              Some(at) => after.split_at(at),
              None => (after, ""),
          };
          let (userinfo, host_port) = match authority.rsplit_once('@') {
              Some((userinfo, host_port)) => (format!("{userinfo}@"), host_port),
              None => (String::new(), authority),
          };
          let (host, port) = match host_port.split_once(':') {
              Some((host, port)) => (host, format!(":{port}")),
              None => (host_port, String::new()),
          };
          let host = if host.eq_ignore_ascii_case("x.com") { "twitter.com" } else { host };
          format!("{scheme}://{userinfo}{host}{port}{path}{fragment}")
      }

      fn axum_dsl_escape_into(out: &mut String, text: &str, attribute: bool) {
          for c in text.chars() {
              match c {
                  '&' => out.push_str("&amp;"),
                  '<' => out.push_str("&lt;"),
                  '>' => out.push_str("&gt;"),
                  '"' if attribute => out.push_str("&quot;"),
                  _ => out.push(c),
              }
          }
      }

      struct AxumDslBody {
          drawn: Vec<String>,
          solo: bool,
          trix: bool,
      }

      fn axum_dsl_write_body(element: ::scraper::ElementRef, body: &AxumDslBody, next: &mut usize, out: &mut String) {
          for child in element.children() {
              if let Some(child) = ::scraper::ElementRef::wrap(child) {
                  let name = child.value().name();
                  if axum_dsl_is_embed(child) {
                      if let Some(drawn) = body.drawn.get(*next) {
                          out.push_str(drawn);
                      }
                      *next += 1;
                      continue;
                  }
                  // RemoveSoloUnfurledLinkText: the embed stands alone, so the paragraphs of the link text go
                  // (a Trix body keeps its wrapping div, which holds the embed instead of the text).
                  if body.solo && !body.trix && name == "p" && !axum_dsl_has_attachment(child) {
                      continue;
                  }
                  out.push('<');
                  out.push_str(name);
                  for (key, value) in child.value().attrs() {
                      out.push(' ');
                      out.push_str(key);
                      out.push_str("=\"");
                      axum_dsl_escape_into(out, value, true);
                      out.push('"');
                  }
                  out.push('>');
                  if body.solo && body.trix && name == "div" {
                      if let Some(drawn) = body.drawn.first() {
                          out.push_str(drawn);
                      }
                  } else if !AXUM_DSL_VOID_TAGS.contains(&name) {
                      axum_dsl_write_body(child, body, next, out);
                  }
                  if !AXUM_DSL_VOID_TAGS.contains(&name) {
                      out.push_str("</");
                      out.push_str(name);
                      out.push('>');
                  }
              } else if let Some(text) = child.value().as_text() {
                  let text: &str = text;
                  axum_dsl_escape_into(out, text, false);
              }
          }
      }

      // The body with each opengraph embed drawn, or None when it holds none.
      fn axum_dsl_draw_embeds(
          html: &str,
          host: &str,
          draw: Option<fn(&str, &str, &str, &str, bool, bool, bool) -> String>,
          draw_mention: Option<fn(i64, &str, &str, &str) -> String>,
          mentions: &[AxumDslMention],
      ) -> Option<String> {
          let host = axum_dsl_request_host(host);
          let fragment = ::scraper::Html::parse_fragment(html);
          let root = fragment.root_element();
          let mut found = Vec::new();
          axum_dsl_find_embeds(root, host, &mut found);
          if found.is_empty() {
              return None;
          }
          let solo = found.len() == 1
              && matches!(&found[0], AxumDslAttachment::Opengraph(embed) if embed.href.as_deref().is_some_and(|href| {
                  let text = axum_dsl_rails_plain_text(root);
                  axum_dsl_normalize_tweet_url(href) == axum_dsl_normalize_tweet_url(text.trim_end_matches(['\n', '\r']))
              }));
          let draw_one = |attachment: &AxumDslAttachment| match attachment {
              AxumDslAttachment::Opengraph(embed) => draw.map(|draw| axum_dsl_draw_opengraph(draw, embed)).unwrap_or_default(),
              AxumDslAttachment::Mention(id) => match (draw_mention, id.and_then(|id| mentions.iter().find(|m| m.id == id))) {
                  (Some(draw), Some(user)) => draw(user.id, &user.name, &user.title, &user.version),
                  _ => String::new(),
              },
          };
          let body = AxumDslBody {
              // ActionText::ContentHelper#render_action_text_attachment chomps the partial it renders, so the
              // partial's own trailing newline never reaches the body.
              drawn: found.iter().map(|a| {
                  let mut drawn = draw_one(a);
                  if drawn.ends_with('\n') {
                      drawn.pop();
                      if drawn.ends_with('\r') {
                          drawn.pop();
                      }
                  }
                  drawn
              }).collect(),
              solo,
              trix: axum_dsl_has_div(root),
          };
          let mut out = String::new();
          axum_dsl_write_body(root, &body, &mut 0, &mut out);
          Some(out)
      }
    RS

    # What `{{ body|editable :profile, host:, mentions: }}` shares: the `value` Rails gives <lexxy-editor> when a message is
    # edited. Two passes over the body, as Rails makes them: RichTextHelper#editable_body rebuilds each attachment from its
    # attachable (content-type and content set to the attachable's rendered partial, chomped; a mention of a user who is
    # gone leaves the editor), then Lexxy's render_custom_attachments_in replaces the content of every attachment without
    # a url by that partial as an ActiveSupport JSON string. A blank body gives no attribute. The partials are the
    # sanitizer's, so a mention's chip is drawn by the one implementation the message presentation uses.
    EDITABLE_RUNTIME = <<~'RS'
      const AXUM_DSL_EDITABLE_VOID: [&str; 18] = [
          "area", "base", "basefont", "bgsound", "br", "col", "embed", "frame", "hr", "img", "input", "keygen", "link", "meta",
          "param", "source", "track", "wbr",
      ];
      const AXUM_DSL_EDITABLE_RAW: [&str; 8] = ["style", "script", "xmp", "iframe", "noembed", "noframes", "plaintext", "noscript"];

      // Nokogiri's HTML5 serialization: `&` and no-break space escaped in text and attributes, `<` and `>` in text only,
      // `"` in attributes only.
      fn axum_dsl_editable_escape(out: &mut String, text: &str, attribute: bool) {
          for c in text.chars() {
              match c {
                  '&' => out.push_str("&amp;"),
                  '\u{a0}' => out.push_str("&nbsp;"),
                  '"' if attribute => out.push_str("&quot;"),
                  '<' if !attribute => out.push_str("&lt;"),
                  '>' if !attribute => out.push_str("&gt;"),
                  _ => out.push(c),
              }
          }
      }

      // scraper keeps an element's attributes in a hash map, so their order in the source is read off the start tags of the
      // attachments: for each <action-text-attachment>, the names of its attributes in the order they were written.
      fn axum_dsl_attachment_orders(source: &str) -> Vec<Vec<String>> {
          let lower = source.to_ascii_lowercase();
          let bytes = source.as_bytes();
          let mut orders = Vec::new();
          let mut from = 0;
          while let Some(found) = lower[from..].find("<action-text-attachment") {
              let mut i = from + found + "<action-text-attachment".len();
              from = i;
              if !bytes.get(i).is_some_and(|b| b.is_ascii_whitespace() || *b == b'/' || *b == b'>') {
                  continue;
              }
              let mut names: Vec<String> = Vec::new();
              loop {
                  while i < bytes.len() && (bytes[i].is_ascii_whitespace() || bytes[i] == b'/') {
                      i += 1;
                  }
                  if i >= bytes.len() || bytes[i] == b'>' {
                      break;
                  }
                  let start = i;
                  i += 1;
                  while i < bytes.len() && !(bytes[i].is_ascii_whitespace() || matches!(bytes[i], b'/' | b'>' | b'=')) {
                      i += 1;
                  }
                  let name = lower[start..i].to_string();
                  if !names.contains(&name) {
                      names.push(name);
                  }
                  while i < bytes.len() && bytes[i].is_ascii_whitespace() {
                      i += 1;
                  }
                  if bytes.get(i) == Some(&b'=') {
                      i += 1;
                      while i < bytes.len() && bytes[i].is_ascii_whitespace() {
                          i += 1;
                      }
                      match bytes.get(i) {
                          Some(&quote) if quote == b'"' || quote == b'\'' => {
                              i += 1;
                              while i < bytes.len() && bytes[i] != quote {
                                  i += 1;
                              }
                              i += 1;
                          }
                          _ => {
                              while i < bytes.len() && !(bytes[i].is_ascii_whitespace() || bytes[i] == b'>') {
                                  i += 1;
                              }
                          }
                      }
                  }
              }
              orders.push(names);
              from = i.min(source.len());
          }
          orders
      }

      // The body as markup again, with `rewrite` given each <action-text-attachment> and its attributes (to change); it
      // answers false to drop the attachment. `orders` is axum_dsl_attachment_orders of the markup that was parsed, and
      // `next` counts the attachments seen.
      fn axum_dsl_editable_write<F: FnMut(::scraper::ElementRef, &mut Vec<(String, String)>) -> bool>(
          element: ::scraper::ElementRef,
          orders: &[Vec<String>],
          next: &mut usize,
          rewrite: &mut F,
          raw: bool,
          out: &mut String,
      ) {
          for child in element.children() {
              if let Some(child) = ::scraper::ElementRef::wrap(child) {
                  let name = child.value().name();
                  let mut attrs: Vec<(String, String)> = child.value().attrs().map(|(k, v)| (k.to_string(), v.to_string())).collect();
                  if name == "action-text-attachment" {
                      let order = orders.get(*next);
                      *next += 1;
                      if let Some(order) = order {
                          let position = |key: &str| order.iter().position(|n| n == key);
                          if attrs.len() == order.len() && attrs.iter().all(|(key, _)| position(key).is_some()) {
                              attrs.sort_by_key(|(key, _)| position(key));
                          }
                      }
                      if !rewrite(child, &mut attrs) {
                          continue;
                      }
                  }
                  out.push('<');
                  out.push_str(name);
                  for (key, value) in &attrs {
                      out.push(' ');
                      out.push_str(key);
                      out.push_str("=\"");
                      axum_dsl_editable_escape(out, value, true);
                      out.push('"');
                  }
                  out.push('>');
                  if AXUM_DSL_EDITABLE_VOID.contains(&name) {
                      continue;
                  }
                  axum_dsl_editable_write(child, orders, next, rewrite, AXUM_DSL_EDITABLE_RAW.contains(&name), out);
                  out.push_str("</");
                  out.push_str(name);
                  out.push('>');
              } else if let Some(text) = child.value().as_text() {
                  let text: &str = text;
                  if raw {
                      out.push_str(text);
                  } else {
                      axum_dsl_editable_escape(out, text, false);
                  }
              } else if let Some(comment) = child.value().as_comment() {
                  let comment: &str = comment;
                  out.push_str("<!--");
                  out.push_str(comment);
                  out.push_str("-->");
              }
          }
      }

      fn axum_dsl_editable_set(attrs: &mut Vec<(String, String)>, name: &str, value: String) {
          match attrs.iter_mut().find(|(key, _)| key == name) {
              Some(entry) => entry.1 = value,
              None => attrs.push((name.to_string(), value)),
          }
      }

      // ActiveSupport::JSON.encode of a string (escape_html_entities_in_json): the json gem's escapes, then `<`, `>` and `&`.
      fn axum_dsl_json_string(text: &str) -> String {
          let mut out = String::with_capacity(text.len() + 2);
          out.push('"');
          for c in text.chars() {
              match c {
                  '"' => out.push_str("\\\""),
                  '\\' => out.push_str("\\\\"),
                  '\n' => out.push_str("\\n"),
                  '\r' => out.push_str("\\r"),
                  '\t' => out.push_str("\\t"),
                  '\u{8}' => out.push_str("\\b"),
                  '\u{c}' => out.push_str("\\f"),
                  '<' => out.push_str("\\u003c"),
                  '>' => out.push_str("\\u003e"),
                  '&' => out.push_str("\\u0026"),
                  c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
                  c => out.push(c),
              }
          }
          out.push('"');
          out
      }

      // What an attachment attaches: an opengraph embed by its content type (it wins over an sgid), else a User by the
      // GlobalID in its sgid, else a mention whose user cannot be found. Any other attachment is None and stays as it is.
      fn axum_dsl_editable_attachable(element: ::scraper::ElementRef, host: &str) -> Option<AxumDslAttachment> {
          let content_type = element.value().attr("content-type").unwrap_or("");
          if content_type.contains(AXUM_DSL_OPENGRAPH) {
              return Some(AxumDslAttachment::Opengraph(axum_dsl_opengraph(element, host)));
          }
          let user = element.value().attr("sgid").and_then(axum_dsl_attachable_gid).filter(|(model, _)| model == "User");
          match user {
              Some((_, id)) => Some(AxumDslAttachment::Mention(Some(id))),
              None if content_type.contains(AXUM_DSL_MENTION) => Some(AxumDslAttachment::Mention(None)),
              None => None,
          }
      }

      // `value="..."` for the editor, or nothing when the body is blank.
      fn axum_dsl_editable_attribute(
          buf: &mut String,
          html: &str,
          host: &str,
          draw_embed: fn(&str, &str, &str, &str, bool, bool, bool) -> String,
          draw_mention: fn(i64, &str, &str, &str) -> String,
          mentions: &[AxumDslMention],
      ) {
          let host = axum_dsl_request_host(host);
          // render_action_text_attachment chomps the partial; None is a mention of a user who is gone
          let draw = |attachment: &AxumDslAttachment| -> Option<String> {
              let mut drawn = match attachment {
                  AxumDslAttachment::Opengraph(embed) => axum_dsl_draw_opengraph(draw_embed, embed),
                  AxumDslAttachment::Mention(id) => {
                      let user = id.and_then(|id| mentions.iter().find(|m| m.id == id))?;
                      draw_mention(user.id, &user.name, &user.title, &user.version)
                  }
              };
              if drawn.ends_with("\r\n") {
                  drawn.truncate(drawn.len() - 2);
              } else if drawn.ends_with('\n') || drawn.ends_with('\r') {
                  drawn.pop();
              }
              Some(drawn)
          };
          // editable_body
          let source = axum_dsl_ruby_strip(html);
          let fragment = ::scraper::Html::parse_fragment(source);
          let mut editable = String::new();
          axum_dsl_editable_write(
              fragment.root_element(),
              &axum_dsl_attachment_orders(source),
              &mut 0,
              &mut |element, attrs| {
                  let Some(attachment) = axum_dsl_editable_attachable(element, host) else { return true };
                  let Some(content) = draw(&attachment) else { return false };
                  let content_type = match attachment {
                      AxumDslAttachment::Opengraph(_) => AXUM_DSL_OPENGRAPH,
                      AxumDslAttachment::Mention(_) => AXUM_DSL_MENTION,
                  };
                  axum_dsl_editable_set(attrs, "content-type", content_type.to_string());
                  axum_dsl_editable_set(attrs, "content", content);
                  true
              },
              false,
              &mut editable,
          );
          if editable.chars().all(char::is_whitespace) {
              return;
          }
          // Lexxy's render_custom_attachments_in
          let source = axum_dsl_ruby_strip(&editable);
          let fragment = ::scraper::Html::parse_fragment(source);
          let mut value = String::new();
          axum_dsl_editable_write(
              fragment.root_element(),
              &axum_dsl_attachment_orders(source),
              &mut 0,
              &mut |element, attrs| {
                  let has_url = attrs.iter().any(|(key, v)| key == "url" && !v.chars().all(char::is_whitespace));
                  if !has_url {
                      if let Some(content) = axum_dsl_editable_attachable(element, host).and_then(|a| draw(&a)) {
                          axum_dsl_editable_set(attrs, "content", axum_dsl_json_string(&content));
                      }
                  }
                  true
              },
              false,
              &mut value,
          );
          buf.push_str("value=\"");
          for c in value.chars() {
              match c {
                  '&' => buf.push_str("&amp;"),
                  '<' => buf.push_str("&lt;"),
                  '>' => buf.push_str("&gt;"),
                  '"' => buf.push_str("&quot;"),
                  '\'' => buf.push_str("&#39;"),
                  c => buf.push(c),
              }
          }
          buf.push('"');
      }
    RS

    module_function

    # Rails' String#all_emoji? (lib/rails_ext/string.rb) over the plain text of an HTML string, for `{% if x|all_emoji %}`.
    EMOJI = <<~'RS'
      fn axum_dsl_all_emoji(html: &str) -> bool {
          static EMOJI: std::sync::LazyLock<::regex::Regex> = std::sync::LazyLock::new(|| {
              ::regex::Regex::new(r"\A(?:\p{Emoji_Presentation}|\p{Extended_Pictographic}|\x{FE0F})+\z").expect("emoji pattern")
          });
          EMOJI.is_match(::ammonia::Builder::empty().clean(html).to_string().trim())
      }
    RS

    def used?(ir) = !!ir["sanitize"] || profiles(ir).any? || !!ir["all_emoji"]

    MENTION_TYPE = "application/vnd.campfire.mention"

    # Whether a sanitizer draws mentions, or a query calls `action_text_attachable_ids`: ATTACHABLE_RUNTIME is written.
    def mentions?(ir) = profiles(ir).any? { |p| p["attachments"]&.key?(MENTION_TYPE) }
    def attachable_ids_sql?(ir) = ir["queries"].to_a.any? { |q| q["sql"].to_s.include?("action_text_attachable_ids(") }
    def attachable?(ir) = mentions?(ir) || attachable_ids_sql?(ir)

    # The declared sanitizers some view named, in declaration order.
    def profiles(ir) = ir["sanitizers"].to_a.select { |s| ir["sanitize_profiles"].to_a.include?(s["name"]) }

    # scraper, for every reader of HTML as a DOM: `deterministic` keeps an element's attributes in source order, as
    # Nokogiri does (without it they are sorted, and a serialized body reorders them). One line, so the emitter's
    # deduplication merges the sanitizer's and opengraph's.
    SCRAPER_DEP = 'scraper = { version = "0.20", features = ["deterministic"] }'

    # The Cargo.toml dependency line, led by a newline like the others: ammonia only when a view sanitises.
    def deps(ir)
      unless used?(ir)
        line = attachable?(ir) ? "\nbase64 = \"0.22\"" : ""
        return plain_text?(ir) ? "#{line}\n#{SCRAPER_DEP}" : line
      end

      # the regex line is written by Emit#regex_dep when the file has regexes of its own
      line = ir["all_emoji"] && ir["regexes"].to_a.empty? ? "\nammonia = \"4\"\nregex = \"1\"" : "\nammonia = \"4\""
      line += "\nbase64 = \"0.22\"" if attachable?(ir)
      # `attachments:` reads a body and a preview's markup as a DOM, as Nokogiri does
      attachments?(ir) || plain_text?(ir) ? "#{line}\n#{SCRAPER_DEP}" : line
    end

    def attachments?(ir) = profiles(ir).any? { |p| p["attachments"] }

    # A view wrote `{{ x|editable :profile, ... }}`: EDITABLE_RUNTIME is written, and each named profile gets its function.
    def editable?(ir) = ir["editable_profiles"].to_a.any?

    # The Rust function a view's `|editable :name` calls.
    def editable_fn_name(name) = "axum_dsl_editable_#{name}_into"

    # A body called `plain_text(html)`: the conversion above is written, with the scraper it reads the HTML with.
    def plain_text?(ir) = ir["builtins"].to_a.include?("plain_text") || action_text_html?(ir)
    def action_text_html?(ir) = ir["builtins"].to_a.include?("action_text_html")
    def sounds?(ir) = profiles(ir).any? { |p| p["sounds"] }

    # The Rust function a view's `{% if x|sound :name %}` calls.
    def sound_fn_name(name) = "axum_dsl_is_sound_#{name}"

    # The Rust function a view's `|sanitize :name` calls.
    def fn_name(name) = "axum_dsl_sanitize_#{name}_into"

    # One declared sanitizer: its builder, built once, and the function that cleans a value into a buffer.
    def profile_lines(profile, renderers = nil, editable: false)
      name = profile["name"]
      renderers ||= {}
      host = profile["attachments"] ? ", host: &str" : ""
      mention_param = profile["attachments"]&.key?(MENTION_TYPE) ? ", mentions: &[AxumDslMention]" : ""
      chain = +""
      chain << ".with_attachments(axum_dsl_attachments_#{name})" if renderers["attachment"] || renderers["mention"]
      chain << ".with_sounds(axum_dsl_sounds_#{name})" if renderers["sounds"]
      extras = []
      if renderers["attachment"] || renderers["mention"]
        og = renderers["attachment"] ? "Some(#{renderers['attachment']})" : "None"
        mention = renderers["mention"] ? "Some(#{renderers['mention']})" : "None"
        extras << <<~RS
          fn axum_dsl_attachments_#{name}(html: &str, host: &str, mentions: &[AxumDslMention]) -> Option<String> {
              axum_dsl_draw_embeds(html, host, #{og}, #{mention}, mentions)
          }

        RS
      end
      if renderers["sounds"]
        extras << <<~RS
          fn axum_dsl_sounds_#{name}(html: &str) -> Option<String> {
              axum_dsl_play_name(html).and_then(|name| axum_dsl_sound_#{name}_render(&name))
          }

          fn #{sound_fn_name(name)}(html: &str) -> bool {
              axum_dsl_sounds_#{name}(html).is_some()
          }

        RS
      end
      list = ->(xs) { "&[#{xs.map { |x| AxumDsl.rstr(x) }.join(', ')}]" }
      autolink = profile["autolink_target"] ? "Some(#{AxumDsl.rstr(profile['autolink_target'])})" : "None"
      lines = <<~RS.lines.map(&:chomp)
        static AXUM_DSL_SANITIZER_#{name.upcase}: std::sync::LazyLock<AxumDslSanitizer> = std::sync::LazyLock::new(|| {
            AxumDslSanitizer::new(#{list.call(profile['tags'])}, #{list.call(profile['attributes'])}, #{profile['link_rel'] != false}, #{autolink})#{chain}
        });

        fn #{fn_name(name)}(buf: &mut String, html: &str#{host}#{mention_param}) {
            AXUM_DSL_SANITIZER_#{name.upcase}.clean_into(buf, html, #{profile["attachments"] ? "host" : %q("")}, #{mention_param.empty? ? "&[]" : "mentions"});
        }

      RS
      if editable
        extras << <<~RS
          fn #{editable_fn_name(name)}(buf: &mut String, html: &str, host: &str, mentions: &[AxumDslMention]) {
              axum_dsl_editable_attribute(buf, html, host, #{renderers["attachment"]}, #{renderers["mention"]}, mentions);
          }

        RS
      end
      [*renderers.fetch("fns", []).flat_map { |f| f.lines.map(&:chomp) + [""] }, *extras.flat_map { |e| e.lines.map(&:chomp) }, *lines]
    end

    # The helpers, followed by a blank line, or nothing at all.
    def items(ir)
      lines = []
      lines.push("// Action Text attachable sgids: written by the compiler", *ATTACHABLE_RUNTIME.lines.map(&:chomp), "") if attachable?(ir)
      if plain_text?(ir)
        lines.push("// `plain_text(html)` (ActionText::PlainTextConversion): written by the compiler")
        lines.push(*RAILS_PLAIN_TEXT.lines.map(&:chomp)) unless attachments?(ir) # the attachments runtime holds it already
        lines.push(*PLAIN_TEXT_CALL.lines.map(&:chomp), "")
        lines.push(*ACTION_TEXT_HTML_CALL.lines.map(&:chomp), "") if action_text_html?(ir)
      end
      return lines unless used?(ir)

      lines.push("// `{% if x|all_emoji %}`: written by the compiler", *EMOJI.lines.map(&:chomp), "") if ir["all_emoji"]
      if ir["sanitize"]
        lines.push("// HTML sanitising for `{{ name|sanitize }}` (ammonia): written by the compiler", *HELPER.lines.map(&:chomp), "")
      end
      unless profiles(ir).empty?
        lines.push("// HTML sanitising for `{{ name|sanitize :profile }}` (ammonia, the file's `sanitizer` declarations): written by the compiler",
                   *PROFILE_RUNTIME.lines.map(&:chomp), "")
        lines.push(*STRIP_RUNTIME.lines.map(&:chomp), "") if sounds?(ir) || attachments?(ir)
        lines.push(*SOUND_RUNTIME.lines.map(&:chomp), "") if sounds?(ir)
        lines.push(*ATTACHMENT_RUNTIME.lines.map(&:chomp), "") if attachments?(ir)
        lines.push("// `{{ x|editable :profile }}` (RichTextHelper#editable_body, Lexxy render_custom_attachments_in): written by the compiler", *EDITABLE_RUNTIME.lines.map(&:chomp), "") if editable?(ir)
        renderers = ir["sanitize_renderers"] || {}
        lines.push(*profiles(ir).flat_map { |p| profile_lines(p, renderers[p["name"]], editable: ir["editable_profiles"].to_a.include?(p["name"])) })
      end
      lines
    end
  end
end
