# expect: declares 2 argument type(s) but its block takes 1
server "refuse", version: "0.1.0"
set :port, 8080

helper :shout, args: [:string, :string], returns: :string do |s|
  s
end

get "/x" do
  text(shout("hi", "there"))
end
