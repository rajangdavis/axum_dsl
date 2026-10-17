# expect: record `Tag` is declared but no query returns it
server "refuse", version: "0.1.0"
set :port, 8080

database :sqlite, path: "x.db"

record :Tag do
  field :name, :string
end

query :count_notes, args: { id: :i64 }, returns: :i64, sql: "SELECT COUNT(*) FROM notes WHERE id = :id"

get "/x" do
  text(count_notes(id: 1).to_s)
end
