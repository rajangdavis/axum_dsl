# expect: reads params `Mixed` from both a JSON body and a form
server "refuse", version: "0.1.0"
set :port, 8080

params :Mixed do
  field :name, :string, in: :form
  field :age,  :i32,    in: :body
end

post "/signup", params: :Mixed do
  text(params[:name])
end
