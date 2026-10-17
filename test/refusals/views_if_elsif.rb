# expect: is not a directive: there is no `{% elsif %}`
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  render :if_elsif, locals: { a: true, b: true }
end