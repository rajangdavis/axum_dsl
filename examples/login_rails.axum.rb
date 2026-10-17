# typed: true
# The Rails cookie format: `format: :rails` signs with ActiveSupport::MessageVerifier's value -- a Marshal
# payload, strict Base64 and HMAC-SHA1 -- not the compiler's own :hmac format. The wire format is a
# compatibility claim, and reading emitted text cannot show a Rails-signed cookie being accepted by the
# running service, so test/e2e_login_rails.sh computes one in Ruby and sends it. The other examples hold
# 8080-8084, 8086, 8087, 8091, 8093, 8095, 8097 and 8098 (test/e2e_notes.sh also starts one on 8085), so this takes 8096.
server "login_rails", version: "0.1.0"
set :port, 8096

# The key every cookie is signed with. format: :rails derives the MessageVerifier key from it with
# PBKDF2-HMAC-SHA1 (salt "signed cookie", 1000 iterations, 64 bytes), as Rails' key generator does.
setting :secret_key, env: "SECRET_KEY_BASE", secret: true
cookies secret: :secret_key, format: :rails

# Writes a signed rails_token and answers the value it wrote. Rails percent-encodes the signed value as
# Rack encodes a cookie, so the Base64 padding arrives as %3D and the e2e decodes it before verifying.
get "/set", description: "Set the signed rails_token cookie and answer its value" do
  set_cookie :rails_token, "tok", http_only: true, same_site: :lax
  "tok"
end

# Reads the cookie back. A value whose signature does not verify reads as nil, so this answers none.
get "/me", description: "The rails_token cookie's value, or none" do
  value = cookie(:rails_token)
  return text("none") if value.nil?
  text(value)
end

# A plain cookie travels beside the signed one: no MAC, still percent-encoded as Rack encodes it.
get "/unsigned", description: "Set the plain plain_token cookie and answer its value" do
  set_cookie :plain_token, "lobby", signed: false
  "lobby"
end

get "/plain", description: "The plain_token cookie's value, or none" do
  value = cookie(:plain_token, signed: false)
  return text("none") if value.nil?
  text(value)
end
