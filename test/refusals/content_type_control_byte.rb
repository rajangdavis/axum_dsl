# expect: content_type is a MIME type written `type/subtype`
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  text("x", content_type: "text/html;\ncharset=utf-8")
end

