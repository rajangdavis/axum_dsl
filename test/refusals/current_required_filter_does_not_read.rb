# expect: but its body never reads `current(:who)`, so it cannot establish it
server "refuse", version: "0.1.0"
set :port, 8080

current :who, returns: :string?, required: :authenticate do
  request_ip
end

before :authenticate do
  "continue"
end

get "/" do
  text(current(:who))
end
