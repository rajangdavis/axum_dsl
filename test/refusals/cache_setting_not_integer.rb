# expect: setting `response_cache_mb` is the response cache's size in MB
server "refuse", version: "0.1.0"
set :port, 8080

database :sqlite, path: "x.db"
query :one, args: {}, returns: :i64, sql: "SELECT 1"

get "/n" do
  "#{one()}"
end

setting :response_cache_mb, env: "RESPONSE_CACHE_MB", default: "64"

get "/x", cache: :private do
  "ok"
end
