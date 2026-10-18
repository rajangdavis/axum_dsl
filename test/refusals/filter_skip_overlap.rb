# expect: the run-time skip (method and path) also matches `get /rooms/me`, which does not skip it
server "refuse", version: "0.1.0"
set :port, 8080

params :Room do
  field :id, :string, in: :path
end

before :authenticate do
  "continue"
end

get "/rooms/:id", params: :Room, skip: [:authenticate] do
  text("room")
end

get "/rooms/me" do
  text("me")
end
