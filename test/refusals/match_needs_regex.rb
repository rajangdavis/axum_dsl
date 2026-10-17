# expect: `match?` needs a regex literal
server "refuse", version: "0.1.0"
set :port, 8080

params :P do
  field :s, :string, in: :query
end

get "/x", params: :P do
  if params[:s].match?("x") then "a" else "b" end
end
