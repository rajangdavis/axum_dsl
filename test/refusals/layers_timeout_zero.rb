# expect: `use_layer :timeout` needs a positive `secs:`, got 0
server "refuse", version: "0.1.0"
set :port, 8080

use_layer :timeout, secs: 0

get "/ping", description: "ping" do
  text("pong")
end
