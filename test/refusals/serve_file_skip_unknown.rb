# expect: serve_file `/files/1` skips `:nope`, but no `before :nope` filter is declared
server "refuse", version: "0.1.0"
set :port, 8080

before :authenticate do
  "continue"
end

serve_file "/files/1", from: "public/skip.txt", skip: [:nope]

get "/" do
  text("ok")
end
