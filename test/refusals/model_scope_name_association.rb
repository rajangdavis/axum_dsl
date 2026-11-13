# expect: `messages` is already an association of the model
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

model :Room, table: :rooms do
  has_many :messages
  scope :messages, -> { where(id: 1) }
end

get "/x" do
  text("x")
end
