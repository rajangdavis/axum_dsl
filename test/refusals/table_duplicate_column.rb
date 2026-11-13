# expect: duplicate column `name` in table `rooms`
server "refuse", version: "0.1.0"
set :port, 8080

table :rooms do
  field :id, :i64
  field :name, :string
  field :name, :string
end

get "/x" do
  text("x")
end
