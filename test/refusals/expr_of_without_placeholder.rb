# expect: so its sql writes that table as `{t}` at least once
server "refuse", version: "0.1.0"
set :port, 8080

expr :n, of: :t, type: :i64, sql: "1"

get "/x" do
  text("x")
end
