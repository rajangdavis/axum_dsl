# expect: has no `{% raw %}` before it
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  render :endraw_stray
end
