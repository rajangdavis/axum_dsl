# expect: no current `ghost` is declared above this body
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  current(:ghost).to_s
end
