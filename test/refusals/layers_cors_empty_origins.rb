# expect: `use_layer :cors` needs at least one origin in `origins:`
server "refuse", version: "0.1.0"
set :port, 8080

use_layer :cors, origins: []

get "/ping", description: "ping" do
  text("pong")
end
