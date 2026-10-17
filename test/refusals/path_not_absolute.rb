# expect: route path must start with /, got
server "refuse", version: "0.1.0"
set :port, 8080

get "items" do
  text("ok")
end
