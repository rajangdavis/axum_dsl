# expect: `use_layer :rate_limit` needs a positive `burst:`, got 0
server "refuse", version: "0.1.0"
set :port, 8080

use_layer :rate_limit, per: 60, burst: 0

get "/ping", description: "ping" do
  text("pong")
end
