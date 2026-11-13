# expect: column `kind` of `rooms` is NOT NULL, so it can not be set to nil
server "refuse", version: "0.1.0"
set :port, 8080

database :sqlite, path: "x.db"

table :rooms do
  field :id, :i64
  field :name, :string, optional: true
  field :kind, :string
end

expr :owned_by, of: :t, type: :bool, args: { who: :i64 }, sql: "{t}.id = :who"
expr :plain_flag, of: :t, type: :bool, sql: "{t}.id = 1"
expr :title_of, of: :t, type: :string, sql: "COALESCE({t}.name, '')"

record :RoomId do
  field :id, :i64
end

model :Room, table: :rooms do
  execute :q, args: { id: :i64 } do where(id: arg(:id)).update_all(kind: nil) end
end

get "/x" do
  text("x")
end
