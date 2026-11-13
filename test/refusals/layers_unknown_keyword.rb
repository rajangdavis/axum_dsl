# expect: unknown keyword `gzip:` for `use_layer` (allowed: origins, secs, forwarded, per, burst, path, enabled, except, security_headers, version, revision, etag, vary_accept, preload, refresh_cookies, session_cookie, cache_mb)
server "refuse", version: "0.1.0"
set :port, 8080

use_layer :compression, gzip: true

get "/ping", description: "ping" do
  text("pong")
end
