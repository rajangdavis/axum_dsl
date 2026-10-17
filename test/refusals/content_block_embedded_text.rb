# expect: `embedded_text` builds an MCP content block
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  embedded_text("https://example.com/x", "body")
end
