# expect: is not a loop; a loop is
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  render :loop_bad_syntax
end
