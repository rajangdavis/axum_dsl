# expect: `format:` applies to a signed cookie
server "refuse", version: "0.1.0"
set :port, 8080

setting :secret_key, env: "SECRET_KEY_BASE"
cookies secret: :secret_key

get "/x" do
  set_cookie :last_room, "lobby", signed: false, format: :rails
  "ok"
end
