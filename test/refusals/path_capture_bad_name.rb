# expect: must start with a letter or _ and contain only letters, digits and _
server "refuse", version: "0.1.0"
set :port, 8080

get "/items/:1x" do
  text("ok")
end
