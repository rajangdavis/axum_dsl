# expect: is passed to this render but no marker reads it
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  render :no_markers, locals: { title: "x" }
end
