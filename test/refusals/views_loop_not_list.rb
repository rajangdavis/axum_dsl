# expect: not a list; `{% for x in xs %}` loops over a list of
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  render :loop_not_list, locals: { xs: "abc" }
end
