# expect: has no `{% for %}` before it
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  render :loop_endfor_stray
end
