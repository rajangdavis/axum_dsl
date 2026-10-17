# expect: needs a database
server "refuse", version: "0.1.0"
set :port, 8080

query :count_notes, args: {}, returns: :i64, sql: "SELECT COUNT(*) FROM notes"

get "/x" do
  text(count_notes.to_s)
end
