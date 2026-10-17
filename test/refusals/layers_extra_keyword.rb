# expect: `use_layer :compression` takes no keywords, so it does not take `secs:`
server "refuse", version: "0.1.0"
set :port, 8080

use_layer :compression, secs: 5

get "/ping", description: "ping" do
  text("pong")
end
