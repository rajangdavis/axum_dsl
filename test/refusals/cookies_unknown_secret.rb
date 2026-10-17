# expect: `cookies secret: :nope` names a setting that is not declared
server "refuse", version: "0.1.0"
set :port, 8080

cookies secret: :nope

get "/x" do
  cookie(:session_token).to_s
end
