# expect: runs in a route, a filter or a `current` body, not in a helper or a binding
server "refuse", version: "0.1.0"
set :port, 8080

database :sqlite, path: "x.db"

query :count_notes, args: { limit: :i64 }, returns: :i64, sql: "SELECT COUNT(*) FROM notes WHERE id < :limit"

helper :count_below, args: [:i64], returns: :i64 do |n|
  count_notes(limit: n)
end

get "/x" do
  text(count_below(5).to_s)
end
