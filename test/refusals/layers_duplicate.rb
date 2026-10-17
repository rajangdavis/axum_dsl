# expect: duplicate `use_layer :compression`
server "refuse", version: "0.1.0"
set :port, 8080

use_layer :compression
use_layer :compression

get "/ping", description: "ping" do
  text("pong")
end
