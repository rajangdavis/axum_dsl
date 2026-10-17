# expect: has no `{% if %}` before it
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  render :if_stray_endif
end