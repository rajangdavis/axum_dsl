# expect: render's status is an integer literal between 100 and 599
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  render :x, status: :unauthorized
end