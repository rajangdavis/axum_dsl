# expect: is a loop variable used outside its `{% for %}`
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  render :loop_var_outside
end
