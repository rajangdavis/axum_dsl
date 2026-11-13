# expect: table `rooms` has no fields
server "refuse", version: "0.1.0"
set :port, 8080

table :rooms do
end

get "/x" do
  text("x")
end
