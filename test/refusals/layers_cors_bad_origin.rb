# expect: `use_layer :cors` origin "example.com" must look like "https://example.com"
server "refuse", version: "0.1.0"
set :port, 8080

use_layer :cors, origins: ["example.com"]

get "/ping", description: "ping" do
  text("pong")
end
