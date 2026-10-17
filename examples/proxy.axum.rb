# typed: true
# A fifth small example, for one declaration: `use_layer :trace, forwarded: true`, which makes the request
# log name the visitor's address (the first X-Forwarded-For entry) instead of the proxy's. It also makes
# the emitted crate depend on tracing and tracing-subscriber, which no other example does.
# test/e2e_proxy.sh drives it; add holds port 8080, views 8091, validate 8093 and assets 8097, so this takes 8095.
server "proxy", version: "0.1.0"
set :port, 8095

use_layer :trace, forwarded: true

get "/ping", description: "Answer pong" do
  text("pong")
end
