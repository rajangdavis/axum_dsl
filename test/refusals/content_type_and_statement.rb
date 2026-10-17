# expect: use one; the statement sets the response default
server "refuse", version: "0.1.0"
set :port, 8080

before do
  content_type(:json)
  text("x", content_type: "text/html")
end

get "/x" do
  text("ok")
end
