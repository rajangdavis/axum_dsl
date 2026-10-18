# expect: says `required: :authenticate`, but no `before :authenticate` filter is declared
server "refuse", version: "0.1.0"
set :port, 8080

current :who, returns: :string?, required: :authenticate do
  request_ip
end

get "/" do
  text(current(:who))
end
