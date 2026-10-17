# typed: true
# CSRF tokens (docs/sessions.md): `use_layer :csrf` puts a token in a signed `_axum_dsl_csrf` cookie, the
# form carries the same token in `authenticity_token` through `{{ csrf_token }}`, and every write whose token
# does not match the cookie is answered 403. `use_layer :fetch_metadata` stays the first-line guard: a
# browser that says the write comes from another site is refused before the token is looked at.
# `make e2e-csrf` builds this file and test/e2e_csrf.sh drives it over HTTP.
server "csrf", version: "0.1.0"
set :port, 8087
set :views, "csrf_views"

# The key the CSRF token's cookie is signed with: at least 32 bytes, or the server exits with status 2 as it
# starts (the same check every signed cookie gets).
setting :secret_key, env: "SECRET_KEY_BASE", secret: true
cookies secret: :secret_key

use_layer :fetch_metadata
use_layer :csrf

params :Note do
  field :body, :string, in: :form
end

get "/form", description: "A form whose hidden field carries the CSRF token" do
  render :form
end

post "/notes", params: :Note, description: "A write: the token must match the signed cookie" do
  text("note: #{params[:body]}")
end
