# expect: route `post /x` has `cache: :private`, but only a `get` route can be cached
server "refuse", version: "0.1.0"
set :port, 8080

database :sqlite, path: "x.db"
query :one, args: {}, returns: :i64, sql: "SELECT 1"

get "/n" do
  "#{one()}"
end

post "/x", cache: :private do
  "ok"
end
