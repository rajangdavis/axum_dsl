# expect: feature "ring lite" must use only letters, digits and _ + . -
server "refuse", version: "0.1.0"
set :port, 8080

rust_crate "tokio-rustls", "0.26", features: ["ring lite"]

get "/ping", description: "ping" do
  text("pong")
end
