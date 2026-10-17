# expect: uses the regex metacharacter
server "refuse", version: "0.1.0"
set :port, 8080

get "/items/[0-9]+" do
  text("ok")
end
