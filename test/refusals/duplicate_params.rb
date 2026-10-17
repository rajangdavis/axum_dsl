# expect: duplicate params `P`
server "refuse", version: "0.1.0"
set :port, 8080

params :P do
  field :x, :string
end

params :P do
  field :y, :string
end

get "/x", params: :P do
  text("ok")
end
