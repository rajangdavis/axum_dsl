# expect: whose value is visible ASCII (0x20-0x7E, or a tab)
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  redirect("/a\n")
end
