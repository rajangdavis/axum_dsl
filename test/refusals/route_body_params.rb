# expect: a route body takes no block parameters
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do |y|
  text("ok")
end
