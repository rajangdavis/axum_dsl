# frozen_string_literal: true

module AxumDsl
  # `webhook_post(url, payload)`: Campfire's Webhook#deliver for one bot (app/models/webhook.rb, from Bot::WebhookJob), the
  # text of the reply the bot then posts, or nil when it posts none:
  # - the payload goes as `POST url` with `Content-Type: application/json`, open and read timeouts of seven seconds
  #   (ENDPOINT_TIMEOUT), no proxy and no private-network guard (Rails': "only an administrator sets this URL");
  # - a 200 whose media type is text/html or text/plain is the reply's text (an empty body included, as Ruby's "" is
  #   truthy); a timeout is "Failed to respond within 7 seconds";
  # - anything else -- another status or type (Rails turns a known MIME type into an attachment reply, which this does
  #   not reproduce), a refused connection, a bad URL -- is no reply.
  module Webhook
    module_function

    CALL = "webhook_post"

    def used?(ir) = ir["builtins"].to_a.include?(CALL)

    def items(ir) = used?(ir) ? RUNTIME.lines.map(&:chomp) + [""] : []

    def deps(ir)
      return "" unless used?(ir)

      "\nreqwest = { version = \"0.12\", default-features = false, features = [\"rustls-tls-native-roots\"] }"
    end

    RUNTIME = <<~'RS'
      async fn axum_dsl_webhook_post(url: &str, payload: &str) -> Option<String> {
          const TIMEOUT: ::std::time::Duration = ::std::time::Duration::from_secs(7);
          const LATE: &str = "Failed to respond within 7 seconds";
          let client = ::reqwest::Client::builder().no_proxy().connect_timeout(TIMEOUT).read_timeout(TIMEOUT).build().ok()?;
          let sent = client.post(url).header("Content-Type", "application/json").body(payload.to_string()).send().await;
          let res = match sent {
              Ok(res) => res,
              Err(e) if e.is_timeout() => return Some(LATE.to_string()),
              Err(e) => {
                  eprintln!("Bot::WebhookJob: {e}");
                  return None;
              }
          };
          let media = res
              .headers()
              .get(::reqwest::header::CONTENT_TYPE)
              .and_then(|v| v.to_str().ok())
              .map(|v| v.split(';').next().unwrap_or("").trim().to_ascii_lowercase());
          let text = res.status() == ::reqwest::StatusCode::OK && matches!(media.as_deref(), Some("text/html" | "text/plain"));
          match res.bytes().await {
              Ok(body) if text => Some(String::from_utf8_lossy(&body).into_owned()),
              Ok(_) => None,
              Err(e) if e.is_timeout() => Some(LATE.to_string()),
              Err(_) => None,
          }
      }
    RS
  end
end
