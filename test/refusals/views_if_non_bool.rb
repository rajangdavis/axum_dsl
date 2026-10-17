# expect: a condition is a `bool` or a nil-able value
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  render :if_non_bool, locals: { title: "Hi" }
end