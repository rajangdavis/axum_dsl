# expect: `from:` does not have it either
server "refuse", version: "0.1.0"
set :port, 8080

database :sqlite, path: "x.db"

record :Note do
  field :id, :i64
  field :title, :string
end

query :find_note, args: { id: :i64 }, returns: :Note?, sql: "SELECT id, title FROM notes WHERE id = :id"

get "/x" do
  note = find_note(id: 1) || raise("gone")
  render :from_missing, from: note
end
