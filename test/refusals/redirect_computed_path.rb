# expect: a redirect path is written in the source, because it becomes the Location header
server "refuse", version: "0.1.0"
set :port, 8080

params :P do
  field :next_path, :string, in: :query
end

get "/x", params: :P do
  redirect(params[:next_path])
end
