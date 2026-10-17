# expect: is `in: :path`, so its type must be a scalar
server "refuse", version: "0.1.0"
set :port, 8080

params :P do
  field :ids, list(:string), in: :path
end

get "/items/:ids", params: :P do
  text("ok")
end
