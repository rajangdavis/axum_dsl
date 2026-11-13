# expect: expr `n` writes `:b` but `args:` does not declare it (declared: a)
server "refuse", version: "0.1.0"
set :port, 8080

expr :n, type: :bool, args: { a: :i64 }, sql: ":a = :b"

get "/x" do
  text("x")
end
