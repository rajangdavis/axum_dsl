# expect: is not an `.html` file
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  render :"signup.erb"
end
