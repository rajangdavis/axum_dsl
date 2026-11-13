# expect: duplicate expr `now`
server "refuse", version: "0.1.0"
set :port, 8080

expr :now, type: :string, sql: "1"
expr :now, type: :string, sql: "2"

get "/x" do
  text("x")
end
