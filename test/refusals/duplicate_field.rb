# expect: duplicate field `x`
server "refuse", version: "0.1.0"
set :port, 8080

params :P do
  field :x, :string
  field :x, :i64
end

get "/x", params: :P do
  text("ok")
end
