# expect: set_cookie `same_site:` is :lax, :strict or :none, written out
server "refuse", version: "0.1.0"
set :port, 8080

setting :secret_key, env: "SECRET_KEY_BASE"
cookies secret: :secret_key

get "/x" do
  set_cookie :session_token, "v", same_site: :sideways
  "ok"
end
