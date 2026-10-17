# expect: duplicate helper `shout`
server "refuse", version: "0.1.0"
set :port, 8080

helper :shout, args: [:string], returns: :string do |s|
  s
end

helper :shout, args: [:string], returns: :string do |s|
  s
end

get "/x" do
  text(shout("hi"))
end
