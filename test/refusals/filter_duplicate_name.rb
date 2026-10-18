# expect: duplicate `before :authenticate` filter
server "refuse", version: "0.1.0"
set :port, 8080

before :authenticate do
  "continue"
end

before :authenticate do
  "continue"
end

get "/" do
  text("ok")
end
