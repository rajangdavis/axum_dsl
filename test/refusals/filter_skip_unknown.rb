# expect: skips `:nope`, but no `before :nope` filter is declared
server "refuse", version: "0.1.0"
set :port, 8080

before :authenticate do
  "continue"
end

get "/", skip: [:nope] do
  text("ok")
end
