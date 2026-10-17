# expect: src/note.txt would overwrite src, which the emitted crate writes itself
server "refuse", version: "0.1.0"
set :port, 8080

static "/assets", dir: "src"

get "/ping", description: "ping" do
  text("pong")
end
