# expect: `resource_link` builds an MCP content block
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  resource_link("https://example.com/x", name: "x")
end
