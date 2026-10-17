# expect: a redirect path can interpolate only a number (i32, i64 or f64) or a bool
server "refuse", version: "0.1.0"
set :port, 8080

params :P do
  field :name, :string, in: :query
end

get "/x", params: :P do
  redirect("/x/#{params[:name]}")
end
