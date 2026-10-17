# expect: needs a string, got
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  render :sanitize_non_string, locals: { count: 3 }
end