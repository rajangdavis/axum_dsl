# expect: `extra` is passed to views/p_unused.html but no marker reads it
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  render :c_partial_unused
end
