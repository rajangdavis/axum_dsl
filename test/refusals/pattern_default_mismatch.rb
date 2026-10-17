# expect: does not match the `pattern:`
server "refuse", version: "0.1.0"
set :port, 8080

params :P do
  field :s, :string, pattern: "^[a-z]+$", default: "ZZZ"
end

get "/x", params: :P do
  text("ok")
end
