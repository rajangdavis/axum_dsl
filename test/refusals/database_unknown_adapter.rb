# expect: `:postgres` is not an adapter yet; `:sqlite` is the only one
server "refuse", version: "0.1.0"
set :port, 8080

database :postgres, path: "x.db"

get "/x" do
  text("ok")
end
