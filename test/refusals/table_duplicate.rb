# expect: duplicate table `rooms`
server "refuse", version: "0.1.0"
set :port, 8080

table :rooms do
  field :id, :i64
end

table :rooms do
  field :id, :i64
end

get "/x" do
  text("x")
end
