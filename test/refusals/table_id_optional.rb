# expect: `id` is the primary key of table `rooms`, which is never NULL
server "refuse", version: "0.1.0"
set :port, 8080

table :rooms do
  field :id, :i64, optional: true
end

get "/x" do
  text("x")
end
