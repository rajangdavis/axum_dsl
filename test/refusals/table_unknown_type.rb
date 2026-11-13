# expect: table field `size` is a column, so its type is one of :string, :i64, :f64, :bool, :time, not :i32
server "refuse", version: "0.1.0"
set :port, 8080

table :rooms do
  field :id, :i64
  field :size, :i32
end

get "/x" do
  text("x")
end
