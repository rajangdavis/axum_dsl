# expect: is never read; remove it, or use it
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  y = "a"
  text("ok")
end
