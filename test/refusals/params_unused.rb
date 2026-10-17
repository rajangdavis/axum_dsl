# expect: is declared but no route uses it
server "refuse", version: "0.1.0"
set :port, 8080

params :P do
  field :x, :string
end

get "/x" do
  text("ok")
end
