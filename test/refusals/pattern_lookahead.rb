# expect: unsupported regex in `pattern:`: lookahead is not supported
server "refuse", version: "0.1.0"
set :port, 8080

params :P do
  field :s, :string, pattern: "(?=x)y"
end

get "/x", params: :P do
  text("ok")
end
