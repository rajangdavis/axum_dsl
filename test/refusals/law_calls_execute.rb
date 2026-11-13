# expect: writes to the database; a law may call `query` statements only
server "refuse", version: "0.1.0"
set :port, 8080

database :sqlite, path: "x.db"
query :one, args: {}, returns: :i64, sql: "SELECT 1"
execute :clear, args: {}, sql: "DELETE FROM t"

get "/n" do
  "#{one()}"
end

law :clears do
  clear() == 0
end
