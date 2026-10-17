# expect: is never closed; a raw region ends with
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  render :raw_unclosed
end
