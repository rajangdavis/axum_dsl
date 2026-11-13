# expect: field `flag` is :bool in record `RoomT`, but the relation gives :i64
server "refuse", version: "0.1.0"
set :port, 8080

database :sqlite, path: "x.db"

table :rooms do
  field :id, :i64
  field :kind, :string
end

record :RoomT do
  field :id, :i64
  field :flag, :bool
end

model :Room, table: :rooms do
  query :q, args: {}, returns: list(:RoomT) do select(:id, flag: 1) end
end

get "/x" do
  text("x")
end
