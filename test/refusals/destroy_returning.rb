# expect: `destroy` takes no arguments
server "refuse", version: "0.1.0"
set :port, 8080

database :sqlite, path: "x.db"

table :rooms do
  field :id, :i64
end

table :memberships do
  field :id, :i64
  field :room_id, :i64
end

model :Membership, table: :memberships do
end

model :Room, table: :rooms do
  has_many :memberships, dependent: :delete_all
  execute :destroy_room, args: { id: :i64 } do
    where(id: arg(:id)).destroy(returning: :id)
  end
end

post "/destroy" do
  rows = transaction do
    destroy_room(id: 1)
  end
  text(rows.to_s)
end
