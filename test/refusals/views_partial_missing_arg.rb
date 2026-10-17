# expect: reads an argument, so the partial call must pass one
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  render :c_partial_missing
end
