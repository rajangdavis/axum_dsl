# expect: do not select the same fields: field 2 is `name` (:string) in query `a_room` and `kind` (:string) here
server "refuse", version: "0.1.0"
set :port, 8080

database :sqlite, path: "x.db"

table :rooms do
  field :id, :i64
  field :name, :string, optional: true
  field :kind, :string
end

model :Room, table: :rooms do
  query :a_room, args: { id: :i64 }, returns: :RoomName? do
    where(id: arg(:id)).select(:id, name: coalesce(:name, ""))
  end

  query :a_kind, args: {}, returns: list(:RoomName) do
    select(:id, :kind)
  end
end

get "/a" do
  json(a_room(id: 1))
end

get "/b" do
  json(a_kind)
end
