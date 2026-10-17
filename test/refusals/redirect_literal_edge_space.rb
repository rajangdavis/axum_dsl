# expect: which carries no leading or trailing whitespace
server "refuse", version: "0.1.0"
set :port, 8080

get "/x" do
  redirect("/x ")
end
