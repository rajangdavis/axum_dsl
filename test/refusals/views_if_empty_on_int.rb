# expect: `.empty?` is for a string or a list
server "refuse", version: "0.1.0"
set :port, 8080

params :Q do
  field :count, :i64
  field :name, :string
  field :on, :bool
end

get "/x", params: :Q do
  render :if_empty_on_int, locals: { count: params[:count] }
end
