# expect: `destroy` changes data, so it belongs in an `execute`
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
  query :gone, args: { id: :i64 }, returns: :i64 do
    where(id: arg(:id)).destroy
  end
end

get "/gone" do
  gone(id: 1).to_s
end
