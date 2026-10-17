# expect: is not a marker; a marker is one of
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  render :malformed
end
