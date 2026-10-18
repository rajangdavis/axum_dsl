# expect: also matches `get /openapi.json`, which does not skip it
server "refuse", version: "0.1.0"
set :port, 8080

before :authenticate do
  "continue"
end

openapi "/openapi.json"

params :DocName do
  field :doc, :string, in: :path
end

get "/:doc", params: :DocName, skip: [:authenticate] do
  text("doc")
end
