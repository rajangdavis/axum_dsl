# expect: `use_layer :csrf` takes no keywords
server "refused", version: "0.1.0"

setting :secret_key, env: "SECRET_KEY_BASE"
cookies secret: :secret_key

use_layer :csrf, secs: 5

get "/x" do
  "ok"
end
