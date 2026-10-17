# expect: `set :listener` injects Rust, which `set :rust, :none` (line 4) refuses
server "refuse", version: "0.1.0"
set :port, 8080
set :rust, :none
set :listener, "tls::TlsListener"

get "/x" do
  "ok"
end
