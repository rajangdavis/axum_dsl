# expect: Bcrypt has no method `nope`
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  Bcrypt.nope("a")
end
