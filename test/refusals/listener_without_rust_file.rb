# expect: names a Rust type, which comes from a rust_file, and this file declares none
server "refuse", version: "0.1.0"
set :port, 8080
set :listener, "tls::TlsListener"

get "/ping", description: "ping" do
  text("pong")
end
