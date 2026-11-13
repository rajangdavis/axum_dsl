# expect: `:i32` is not one of :string :i64 :f64 :bool
server "refuse", version: "0.1.0"
set :port, 8080

expr :n, type: :i32, sql: "1"

get "/x" do
  text("x")
end
