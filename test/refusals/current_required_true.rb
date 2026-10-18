# expect: `required: true` cannot say which filter stops the request
server "refuse", version: "0.1.0"
set :port, 8080

current :who, returns: :string?, required: true do
  request_ip
end

get "/" do
  text(current(:who))
end
