# expect: uses a `?` placeholder
server "refuse", version: "0.1.0"
set :port, 8080

database :sqlite, path: "x.db"

query :count_notes, args: { limit: :i64 }, returns: :i64, sql: "SELECT COUNT(*) FROM notes WHERE id < ?"

get "/x" do
  text(count_notes(limit: 1).to_s)
end
