# expect: `rust_fn` injects Rust, which `set :rust, :none` (line 4) refuses
server "refuse", version: "0.1.0"
set :port, 8080
set :rust, :none

rust_fn :shout, args: [:string], returns: :string

get "/x" do
  rust(:shout, "a")
end
