# expect: duplicate partial argument `label`
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  render :c_partial_dup
end
