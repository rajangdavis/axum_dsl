# expect: must be named like 001_create_notes.sql
server "refuse", version: "0.1.0"
set :port, 8080

database :sqlite, path: "x.db"

migrations "bad_migrations"

query :count_notes, args: {}, returns: :i64, sql: "SELECT COUNT(*) FROM notes"

get "/x" do
  text(count_notes.to_s)
end
