# expect: `set :rust` takes :none, the mode that refuses injected Rust
server "refuse", version: "0.1.0"
set :port, 8080
set :rust, :all

get "/x" do
  "ok"
end
