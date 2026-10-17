# expect: is declared but no route or filter calls it
server "refuse", version: "0.1.0"
set :port, 8080

database :sqlite, path: "x.db"

query :count_notes, args: {}, returns: :i64, sql: "SELECT COUNT(*) FROM notes"

get "/x" do
  text("ok")
end
