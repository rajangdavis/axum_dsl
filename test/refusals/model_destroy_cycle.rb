# expect: goes round in a circle (Node -> Node)
server "refuse", version: "0.1.0"
set :port, 8080

table :nodes do
  field :id, :i64
  field :parent_id, :i64
end

model :Node, table: :nodes do
  has_many :children, table: :nodes, foreign_key: :parent_id, dependent: :destroy
end

get "/x" do
  text("x")
end
