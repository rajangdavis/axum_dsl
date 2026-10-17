# expect: `rust_file` injects Rust, which `set :rust, :none` (line 4) refuses
server "refuse", version: "0.1.0"
set :port, 8080
set :rust, :none

rust_file "rust/shout.rs", as: :shout

get "/x" do
  "ok"
end
