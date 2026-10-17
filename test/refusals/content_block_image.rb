# expect: `image` builds an MCP content block
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  image("aGVsbG8=", "image/png")
end
