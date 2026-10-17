# expect: is already defined (no reassignment)
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  x = "a"
  x = "b"
  text(x)
end
