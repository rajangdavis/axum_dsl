# Vet-only fixture (bin/vet_lock): never built or run. It calls the outbound and conversion builtins whose crates
# no example uses: opengraph_unfurl (reqwest, scraper), webhook_post (reqwest), web_push (p256, hkdf, aes-gcm),
# image_variant (libloading) and plain_text (scraper). An example that exercises them replaces this file.
server "vet_outbound", version: "0.1.0"
set :port, 8080

get "/unfurl" do
  found = opengraph_unfurl("https://example.com")
  text(found || "")
end

get "/hook" do
  reply = webhook_post("https://example.com/hook", "{}")
  text(reply || "")
end

get "/push" do
  refused = web_push("https://example.com/push", "p256dh", "auth", "{}", "public", "private", "mailto:a@example.com")
  text("#{refused}")
end

get "/variant" do
  variant = image_variant("storage/a.png", "a.webp", 512, 512)
  text(variant&.filename || "")
end

get "/plain" do
  text(plain_text("<p>hi</p>"))
end
