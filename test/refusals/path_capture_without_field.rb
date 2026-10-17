# expect: but no field of params `P` is `in: :path`
server "refuse", version: "0.1.0"
set :port, 8080

params :P do
  field :q, :string, in: :query
end

get "/items/:id", params: :P do
  text("ok")
end
