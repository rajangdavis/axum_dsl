# expect: read it inside `{% if page %}`
server "refuse", version: "0.1.0"
set :port, 8080

database :sqlite, path: "x.db"

record :Item do
  field :id, :i64
  field :name, :string
end

query :find_item, args: { id: :i64 }, returns: :Item?, sql: "SELECT id, name FROM items WHERE id = :id"

get "/x" do
  page = find_item(id: 1)
  render :dotted_nil_able_record, locals: { page: page }
end
