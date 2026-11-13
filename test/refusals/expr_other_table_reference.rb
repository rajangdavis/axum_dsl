# expect: takes one table reference, `{t}`, and its sql also writes `{u}`
server "refuse", version: "0.1.0"
set :port, 8080

expr :n, of: :t, type: :i64, sql: "{t}.id + {u}.id"

get "/x" do
  text("x")
end
