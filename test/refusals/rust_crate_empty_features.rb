# expect: needs at least one name in `features:`
server "refuse", version: "0.1.0"
set :port, 8080

rust_crate "tokio-rustls", "0.26", features: []

get "/ping", description: "ping" do
  text("pong")
end
