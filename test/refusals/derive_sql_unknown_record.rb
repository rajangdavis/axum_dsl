# expect: query `by_sql` returns record `Nope`, which is not declared
server "refuse", version: "0.1.0"
set :port, 8080

database :sqlite, path: "x.db"

table :rooms do
  field :id, :i64
end

# Only a relation derives its record; SQL text keeps the record it names or is refused.
query :by_sql, args: {}, returns: list(:Nope), sql: "SELECT id FROM rooms"

get "/s" do
  json(by_sql)
end
