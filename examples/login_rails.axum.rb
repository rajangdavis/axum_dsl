# typed: true
# The Rails cookie formats: `format: :rails` signs the classic ActiveSupport::MessageVerifier value -- a
# Marshal payload, strict Base64 and HMAC-SHA1 -- and `format: :rails7` (used per call below) signs the
# JSON/`_rails` value a default Rails 7/8 app reads, not the compiler's own :hmac format.
# The wire format is a
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

# Rails 7/8's default signed cookie: the `:json` serializer and the `_rails` metadata envelope, with the
# key derived by PBKDF2-HMAC-SHA256 (Rails 7.0+ framework defaults). It is opt-in per call with
# `format: :rails7`, so the declaration's classic `:rails` value above stays byte-identical.
get "/set7", description: "Set the signed rails7_token cookie and answer its value" do
  set_cookie :rails7_token, "tok", http_only: true, same_site: :lax, format: :rails7
  "tok"
end

# Reads the rails7 cookie back; a malformed envelope, a wrong purpose, an expired exp or a signature that
# does not verify reads as nil, so this answers none.
get "/me7", description: "The rails7_token cookie's value, or none" do
  value = cookie(:rails7_token, format: :rails7)
  return text("none") if value.nil?
  text(value)
end

# Rails' permanent signed cookie: `cookies.signed.permanent[:rails7_token]` writes
# `expires = 20.years.from_now`, and Messages::Metadata.pick_expiry puts it in the signed envelope as
# `expires_at.utc.iso8601(3)` (a UTC ISO8601 string), separate from the Set-Cookie `Max-Age` the browser
# honours. Both are written here; the value still reads back through /me7 until that instant passes.
get "/set7permanent", description: "Set a permanent rails7_token cookie and answer its value" do
  set_cookie :rails7_token, "tok", http_only: true, same_site: :lax, permanent: true, format: :rails7
  "tok"
end

# `max_age:` writes the same ISO8601 string exp at now + 60 for a minute-long cookie; a non-permanent
# Rails 7/8 cookie with a null exp is still read, as /set7 and the hand-made values show.
get "/set7maxage", description: "Set a rails7 cookie that expires in a minute and answer its value" do
  set_cookie :rails7_token, "tok", http_only: true, same_site: :lax, max_age: 60, format: :rails7
  "tok"
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
