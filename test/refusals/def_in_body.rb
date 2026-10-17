# expect: unsupported DefNode as a statement
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  def helper(x) = x
  text("ok")
end
