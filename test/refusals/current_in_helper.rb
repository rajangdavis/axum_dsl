# expect: current(:name) reads the request: use it in a route, a `before` filter or a `current` body, not in a helper
server "refuse", version: "0.1.0"
set :port, 8080

current :stamp, returns: :string do
  "x"
end

helper :stamped, args: [], returns: :string do
  current(:stamp)
end

get "/x" do
  stamped
end
