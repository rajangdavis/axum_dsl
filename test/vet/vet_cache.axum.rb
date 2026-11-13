# Vet-only fixture (bin/vet_lock): never built or run. It turns on the modules that need a database or a layer:
# set :log, :json (tracing-subscriber's json feature), use_layer :front (httpdate, flate2) and `cache: :private`
# (sha2, flate2). An example that exercises them replaces this file.
server "vet_cache", version: "0.1.0"
set :port, 8080
set :log, :json
use_layer :front

database :sqlite, path: "vet.db"
query :one, args: {}, returns: :i64, sql: "SELECT 1"

setting :response_cache_mb, env: "RESPONSE_CACHE_MB", default: 64, type: :i64

get "/n" do
  "#{one()}"
end

get "/x", cache: :private do
  "ok"
end
