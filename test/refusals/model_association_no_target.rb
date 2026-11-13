# expect: model "Room" has_one :search_row: name the target with `model:` or `table:`
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
  has_one :search_row
end

get "/x" do
  text("x")
end
