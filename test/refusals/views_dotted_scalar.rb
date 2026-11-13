# expect: which has no fields
server "refuse", version: "0.1.0"
set :port, 8080

params :Q do
  field :count, :i64
  field :name, :string
  field :on, :bool
end

get "/x", params: :Q do
  render :dotted_scalar, locals: { name: params[:name] }
end
