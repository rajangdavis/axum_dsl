# expect: a string literal cannot be prepended with `+`
server "refuse", version: "0.1.0"
set :port, 8080

params :P do
  field :s, :string, in: :query
end

get "/x", params: :P do
  "pre" + params[:s]
end
