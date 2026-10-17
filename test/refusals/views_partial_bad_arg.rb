# expect: an argument is named by a bare word and a colon
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  render :c_partial_bad_arg
end
