# expect: argument `id` calls statement `find_note` inside the `transaction` block
server "refuse", version: "0.1.0"
set :port, 8080

database :sqlite, path: "x.db"

query :find_note, args: { id: :i64 }, returns: :i64, sql: "SELECT id FROM notes WHERE id = :id"
execute :add_note, args: { id: :i64 }, sql: "INSERT INTO notes (id) VALUES (:id)"

post "/notes" do
  transaction do
    add_note(id: find_note(id: 1))
    find_note(id: 1)
  end
end
