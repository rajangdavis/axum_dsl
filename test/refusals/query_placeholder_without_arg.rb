# expect: the SQL uses `:limit` but `args:` does not declare it
server "refuse", version: "0.1.0"
set :port, 8080

database :sqlite, path: "x.db"

query :count_notes, args: {}, returns: :i64, sql: "SELECT COUNT(*) FROM notes WHERE id < :limit"

get "/x" do
  text(count_notes.to_s)
end
