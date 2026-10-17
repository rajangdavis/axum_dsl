# expect: current `stamp` is declared but nothing reads it
server "refuse", version: "0.1.0"
set :port, 8080

current :stamp, returns: :string do
  "x"
end

get "/x" do
  "ok"
end
