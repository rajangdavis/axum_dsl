# expect: text's content_type is a string literal, such as `content_type: "text/html"`
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  text("x", content_type: :json)
end
