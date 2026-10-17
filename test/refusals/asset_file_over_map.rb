# expect: axum_dsl.map.json would overwrite axum_dsl.map.json, which the emitted crate writes itself
server "refuse", version: "0.1.0"
set :port, 8080

file "axum_dsl.map.json", as: :clash

get "/ping", description: "ping" do
  text("pong")
end
