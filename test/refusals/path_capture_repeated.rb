# expect: repeats the capture name `id`
server "refuse", version: "0.1.0"
set :port, 8080

get "/items/:id/:id" do
  text("ok")
end
