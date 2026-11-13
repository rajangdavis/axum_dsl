# expect: the default of `n:` in `{% args %}` is String
server "refuse", version: "0.1.0"
set :port, 8080

params :Q do
  field :count, :i64
  field :name, :string
  field :on, :bool
end

get "/x", params: :Q do
  render :args_default_type, locals: { n: params[:count] }
end
