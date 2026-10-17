# expect: uses a group in parentheses
server "refuse", version: "0.1.0"
set :port, 8080

get "/items/(\\d+)" do
  text("ok")
end
