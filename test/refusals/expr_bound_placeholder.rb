# expect: has the placeholder `:id` in its sql
server "refuse", version: "0.1.0"
set :port, 8080

expr :n, type: :i64, sql: "id = :id"

get "/x" do
  text("x")
end
