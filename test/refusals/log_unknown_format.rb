# expect: `set :log` is :text or :json, got :yaml
server "refuse", version: "0.1.0"
set :port, 8080
set :log, :yaml

get "/ping", description: "ping" do
  text("pong")
end
