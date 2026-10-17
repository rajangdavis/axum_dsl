# expect: no view at views/p_nowhere.html
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  render :c_partial_missing_file
end
