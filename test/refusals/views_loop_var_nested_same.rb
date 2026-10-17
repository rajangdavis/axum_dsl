# expect: is already the variable of an enclosing `{% for %}`
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  render :loop_var_nested_same
end
