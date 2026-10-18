# expect: but this route skips `:authenticate`
server "refuse", version: "0.1.0"
set :port, 8080

current :who, returns: :string?, required: :authenticate do
  request_ip
end

before :authenticate do
  return redirect("/login") if current(:who).nil?
  "continue"
end

get "/me", skip: [:authenticate] do
  text(current(:who))
end
