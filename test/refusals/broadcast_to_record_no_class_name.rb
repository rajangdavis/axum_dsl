# expect: Room has no field `class_name`
server "refuse", version: "0.1.0"
set :port, 8080
setting :secret_key, env: "SECRET_KEY_BASE", secret: true
cookies secret: :secret_key
current :user, returns: :string? do
  cookie(:who)
end

database :sqlite, path: "x.db"

record :Room do
  field :id, :i64
  field :kind, :string
end

query :room_by_id, args: { id: :i64 }, returns: :Room?, sql: "SELECT id, kind FROM rooms WHERE id = :id"

cable "/cable", authenticate_with: :user do
  channel "BoardChannel", signed_stream: :secret_key
end

get "/x" do
  room = room_by_id(id: 1)
  return halt(404, "") if room.nil?
  broadcast_remove_to room, :messages, target: "x", app: "campfire"
  text("sent")
end
