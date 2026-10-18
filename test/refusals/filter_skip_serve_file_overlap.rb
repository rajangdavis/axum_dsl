# expect: also matches `get /files/1`, which does not skip it
server "refuse", version: "0.1.0"
set :port, 8080

before :authenticate do
  "continue"
end

params :FileId do
  field :id, :string, in: :path
end

get "/files/:id", params: :FileId, skip: [:authenticate] do
  text("file")
end

serve_file "/files/1", from: "public/skip.txt"
