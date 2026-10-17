# expect: `each` needs a list or a map, got String
server "refuse", version: "0.1.0"
set :port, 8080

params :P do
  field :s, :string, in: :query
end

get "/x", params: :P do
  params[:s].each { |c| text("x") }
  text("ok")
end
