# expect: so it is only there in a route that names `params:`
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  text("hello #{errors[:name]}")
end
