# expect: `{% args %}` declares a partial
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  render :c_args_in_view
end