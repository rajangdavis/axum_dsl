# expect: `static "/"` is axum's fallback for every GET path, so a `skip:` on it cannot be scoped
server "refuse", version: "0.1.0"
set :port, 8080

before :authenticate do
  "continue"
end

static "/", dir: "public", skip: [:authenticate]

get "/" do
  text("pong")
end
