# expect: `name:` renames a form field's wire key, so field `body` must be `in: :form`
server "refuse", version: "0.1.0"
set :port, 8080

params :Message do
  field :body, :string, in: :body, name: "message[body]"
end

post "/messages", params: :Message do
  text(params[:body])
end
