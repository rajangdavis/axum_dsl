# expect: `rust_fn` injects Rust, which `set :rust, :none` (line 7) refuses
server "refuse", version: "0.1.0"
set :port, 8080

rust_fn :shout, args: [:string], returns: :string

set :rust, :none

get "/x" do
  rust(:shout, "a")
end
