# expect: so the generated check() can never report a violation
server "refuse", version: "0.1.0"
set :port, 8080

params :Loose do
  field :x, :string
end

get "/x", params: :Loose do
  text("hello #{params[:x]} #{errors[:x]}")
end
