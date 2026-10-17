# expect: is only meaningful in a `before` filter, not in `not_found`
server "refuse", version: "0.1.0"
set :port, 8080

not_found do
  content_type(:json)
  text("ok")
end
