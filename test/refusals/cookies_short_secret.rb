# expect: the default of setting `secret_key` is 5 bytes, and the key cookies are signed with must be at least 32
server "refuse", version: "0.1.0"
set :port, 8080

setting :secret_key, env: "SECRET_KEY_BASE", default: "short"
cookies secret: :secret_key

get "/x" do
  cookie(:session_token).to_s
end
