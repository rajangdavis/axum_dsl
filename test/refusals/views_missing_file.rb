# expect: no view at views/nowhere.html
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  render :nowhere
end
