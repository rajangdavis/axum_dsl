# expect: argument `body` calls helper `body_for` inside the `transaction` block
server "refuse", version: "0.1.0"
set :port, 8080

database :sqlite, path: "x.db"

helper :body_for, args: [:string], returns: :string do |s|
  s
end

query :count_notes, args: {}, returns: :i64, sql: "SELECT COUNT(*) FROM notes"
execute :add_note, args: { body: :string }, sql: "INSERT INTO notes (body) VALUES (:body)"

get "/x" do
  text(body_for("hi"))
end

post "/notes" do
  transaction do
    add_note(body: body_for("hi"))
    count_notes
  end
end
