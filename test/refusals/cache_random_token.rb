# expect: but its body calls `random_token`, whose result a database commit does not explain
server "refuse", version: "0.1.0"
set :port, 8080

database :sqlite, path: "x.db"
query :one, args: {}, returns: :i64, sql: "SELECT 1"

get "/n" do
  "#{one()}"
end

get "/x", cache: :private do
  random_token
end
