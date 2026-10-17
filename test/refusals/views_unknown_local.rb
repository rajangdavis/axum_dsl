# expect: reads a local, so the render must pass it
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  render :unknown_local
end
