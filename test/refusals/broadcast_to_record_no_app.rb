# expect: broadcast_remove_to with a record needs `app:`
server "refuse", version: "0.1.0"
set :port, 8080
setting :secret_key, env: "SECRET_KEY_BASE", secret: true
cookies secret: :secret_key
current :user, returns: :string? do
  cookie(:who)
end

database :sqlite, path: "x.db"

record :RoomClass do
  field :id, :i64
  field :class_name, :string
end

query :room_class_by_id, args: { id: :i64 }, returns: :RoomClass?, sql: "SELECT id, type AS class_name FROM rooms WHERE id = :id"

cable "/cable", authenticate_with: :user do
  channel "BoardChannel", signed_stream: :secret_key
end

get "/x" do
  room = room_class_by_id(id: 1)
  return halt(404, "") if room.nil?
  broadcast_remove_to room, :messages, target: "x"
  text("sent")
end
