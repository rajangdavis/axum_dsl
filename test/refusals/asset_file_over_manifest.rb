# expect: .axum_dsl-files would overwrite .axum_dsl-files, which the emitted crate writes itself
server "refuse", version: "0.1.0"
set :port, 8080

file ".axum_dsl-files", as: :clash

get "/ping", description: "ping" do
  text("pong")
end
