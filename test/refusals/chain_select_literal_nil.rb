# expect: a selected `nil` has no type
server "refuse", version: "0.1.0"
set :port, 8080

database :sqlite, path: "x.db"

table :rooms do
  field :id, :i64
  field :kind, :string
end

record :RoomT do
  field :id, :i64
  field :tag, :string
end

model :Room, table: :rooms do
  query :q, args: {}, returns: list(:RoomT) do select(:id, tag: nil) end
end

get "/x" do
  text("x")
end
