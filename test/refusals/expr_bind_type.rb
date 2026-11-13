# expect: expr `owned_by` takes `who` as :i64, but this value is :string
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
  query :q, args: { u: :string }, returns: list(:RoomId) do where(expr(:owned_by, who: arg(:u))).select(:id) end
end

get "/x" do
  text("x")
end
