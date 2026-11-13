# expect: `from:` takes a record
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  render :unknown_local, from: "x"
end
