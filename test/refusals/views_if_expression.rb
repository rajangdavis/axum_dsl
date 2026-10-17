# expect: is not a condition
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  render :if_expression, locals: { a: 1, b: 2 }
end