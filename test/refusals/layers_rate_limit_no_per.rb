# expect: `use_layer :rate_limit` needs `per:` (the window in seconds)
server "refuse", version: "0.1.0"
set :port, 8080

use_layer :rate_limit, burst: 10

get "/ping", description: "ping" do
  text("pong")
end
