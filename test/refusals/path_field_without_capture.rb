# expect: says `in: :path`, but route path
server "refuse", version: "0.1.0"
set :port, 8080

params :P do
  field :id, :i64, in: :path
end

get "/items", params: :P do
  text("ok")
end
