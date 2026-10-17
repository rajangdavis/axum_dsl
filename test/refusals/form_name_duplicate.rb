# expect: is already the wire key of another field in params `Message`
server "refuse", version: "0.1.0"
set :port, 8080

params :Message do
  field :body, :string, in: :form, name: "message[body]"
  field :client_message_id, :string, in: :form, name: "message[body]"
end

post "/messages", params: :Message do
  text(params[:body])
end
