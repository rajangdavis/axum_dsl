# expect: `blob` builds an MCP resource content
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  blob("aGVsbG8=")
end
