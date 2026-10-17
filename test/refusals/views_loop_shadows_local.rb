# expect: is already a local; a loop variable is a new name
server "refuse", version: "0.1.0"
set :port, 8080

database :sqlite, path: "x.db"

record :Item do
  field :id, :i64
  field :name, :string
  field :note, :string, optional: true
end

query :all_items, args: {}, returns: list(:Item), sql: "SELECT id, name, note FROM items"

get "/x" do
  render :loop_shadows_local, locals: { items: all_items(), item: "x" }
end
