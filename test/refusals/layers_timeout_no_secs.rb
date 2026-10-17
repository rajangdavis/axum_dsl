# expect: `use_layer :timeout` needs `secs:` (a positive whole number of seconds)
server "refuse", version: "0.1.0"
set :port, 8080

use_layer :timeout

get "/ping", description: "ping" do
  text("pong")
end
