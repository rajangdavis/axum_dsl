# expect: empty body
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
end
