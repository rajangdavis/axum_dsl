# expect: has no association :users or :user
server "refuse", version: "0.1.0"
set :port, 8080

table :rooms do
  field :id, :i64
  field :creator_id, :i64
end

table :messages do
  field :id, :i64
  field :room_id, :i64
end

table :users do
  field :id, :i64
end

model :Message, table: :messages do
end

model :Room, table: :rooms do
  has_many :messages
  has_many :users, through: :messages
end

get "/x" do
  text("x")
end
