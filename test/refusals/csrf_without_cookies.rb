# expect: needs `cookies secret: :setting_name`
# The CSRF token is a signed cookie, so the layer has no key without the cookies declaration.
server "refused", version: "0.1.0"

use_layer :csrf

get "/x" do
  "ok"
end
