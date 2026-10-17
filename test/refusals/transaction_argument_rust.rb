# expect: argument `body` calls `rust(...)` inside the `transaction` block
server "refuse", version: "0.1.0"
set :port, 8080

database :sqlite, path: "x.db"

rust_fn :shout, args: [:string], returns: :string

query :count_notes, args: {}, returns: :i64, sql: "SELECT COUNT(*) FROM notes"
execute :add_note, args: { body: :string }, sql: "INSERT INTO notes (body) VALUES (:body)"

get "/x" do
  text(rust(:shout, "hi"))
end

post "/notes" do
  transaction do
    add_note(body: rust(:shout, "hi"))
    count_notes
  end
end
