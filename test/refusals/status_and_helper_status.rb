# expect: use one; the statement applies to the final response, a helper's status: belongs to that value
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  status(401)
  render :if_non_bool, status: 200, locals: { title: "Hi" }
end
