# expect: `required:` is for a nil-able current
server "refuse", version: "0.1.0"
set :port, 8080

current :who, returns: :string, required: :authenticate do
  "ada"
end

before :authenticate do
  "continue"
end

get "/" do
  text(current(:who))
end
