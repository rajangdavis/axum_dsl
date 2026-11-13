# expect: writes `{t}` but has no `of:`
server "refuse", version: "0.1.0"
set :port, 8080

expr :n, type: :i64, sql: "{t}.id"

get "/x" do
  text("x")
end
