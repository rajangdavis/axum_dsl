# expect: field `id` is :string in record `RoomStr`, but the relation gives :i64
server "refuse", version: "0.1.0"
set :port, 8080

database :sqlite, path: "x.db"

table :rooms do
  field :id, :i64
  field :name, :string, optional: true
  field :kind, :string
end

table :memberships do
  field :id, :i64
  field :room_id, :i64
  field :user_id, :i64
end

expr :now, type: :string, sql: "strftime('%Y-%m-%d %H:%M:%f', 'now')"

record :RoomId do
  field :id, :i64
end
record :RoomStr do
  field :id, :string
end

model :Room, table: :rooms do
  has_many :memberships
  scope :directs, -> { where(kind: "direct") }
  scope :visible_to, ->(uid) { joins(:memberships).where(memberships: { user_id: uid }) }
query :q, args: {}, returns: list(:RoomStr) do select(:id) end
end

get "/x" do
  text("x")
end
