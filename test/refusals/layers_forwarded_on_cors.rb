# expect: `use_layer :cors` takes `origins:`, so it does not take `forwarded:`
server "refuse", version: "0.1.0"
set :port, 8080

use_layer :cors, forwarded: true

get "/ping", description: "ping" do
  text("pong")
end
