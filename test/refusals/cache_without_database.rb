# expect: route `get /x` has `cache: :private`, which watches the database for commits
server "refuse", version: "0.1.0"
set :port, 8080

get "/x", cache: :private do
  "ok"
end
