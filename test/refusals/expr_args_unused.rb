# expect: declares `args: { a: ... }` but its sql never writes `:a`
server "refuse", version: "0.1.0"
set :port, 8080

expr :n, type: :bool, args: { a: :i64 }, sql: "1 = 1"

get "/x" do
  text("x")
end
