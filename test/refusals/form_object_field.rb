# expect: is `in: :form`, so its type must be a scalar
server "refuse", version: "0.1.0"
set :port, 8080

params :Address do
  field :city, :string
end

params :P do
  field :home, :Address, in: :form
end

post "/x", params: :P do
  text("ok")
end
