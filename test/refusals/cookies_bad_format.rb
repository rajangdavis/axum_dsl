# expect: `:json` is not one of :hmac :rails :rails7
server "refuse", version: "0.1.0"
set :port, 8080

setting :secret_key, env: "SECRET_KEY_BASE"
cookies secret: :secret_key, format: :json

get "/x" do
  cookie(:session_token).to_s
end
