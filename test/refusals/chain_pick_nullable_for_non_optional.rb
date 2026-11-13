# expect: `pick` gives :string?, but `returns:` says :string; a pick may find no row or a NULL
server "refuse", version: "0.1.0"
set :port, 8080

database :sqlite, path: "x.db"

table :rooms do
  field :id, :i64
  field :name, :string, optional: true
  field :kind, :string
end

model :Room, table: :rooms do
  query :q, args: {}, returns: :string do pick(group_concat(:kind)) end
end

get "/x" do
  text("x")
end
