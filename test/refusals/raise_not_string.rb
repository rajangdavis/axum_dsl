# expect: `raise` needs a string message
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  raise 1
end
