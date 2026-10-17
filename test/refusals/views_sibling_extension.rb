# expect: is not a view: views/sibling.erb is there instead
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  render :sibling
end
