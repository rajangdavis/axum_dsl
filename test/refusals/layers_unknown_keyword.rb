# expect: unknown keyword `gzip:` for `use_layer` (allowed: origins, secs, forwarded, per, burst, path)
server "refuse", version: "0.1.0"
set :port, 8080

use_layer :compression, gzip: true

get "/ping", description: "ping" do
  text("pong")
end
