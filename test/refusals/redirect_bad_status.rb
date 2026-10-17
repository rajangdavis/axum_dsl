# expect: a redirect status must be one of 301, 302, 303, 307, 308
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  redirect("/x", status: 200)
end