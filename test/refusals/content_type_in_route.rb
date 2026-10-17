# expect: is only meaningful in a `before` filter; it sets the default
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  content_type(:json)
  text("ok")
end
