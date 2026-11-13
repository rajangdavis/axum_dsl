# expect: `model: :Usr` is not a declared model
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
  belongs_to :creator, model: :Usr
end

get "/x" do
  text("x")
end
