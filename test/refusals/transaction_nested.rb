# expect: a `transaction` cannot nest
server "refuse", version: "0.1.0"
set :port, 8080

database :sqlite, path: "x.db"
query :count_notes, args: {}, returns: :i64, sql: "SELECT COUNT(*) FROM notes"

get "/x" do
  transaction do
    id = transaction do
      count_notes
    end
    id
  end
end