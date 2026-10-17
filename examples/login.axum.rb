# typed: false
# Sessions with no Rust of the app's own (docs/sessions.md): a signed session cookie, a per-request `current` user,
# Bcrypt, and the Fetch Metadata guard against cross-site writes, all compiled in. `set :rust, :none` makes the
# compiler refuse anything in this file that would inject Rust. The shape is Campfire's: a `sessions` table holds
# a random token, the cookie holds that token signed with SECRET_KEY_BASE, and logging out deletes both.
# `typed: false` because Sorbet knows the DSL's calls (rbi/dsl.rbi) but not the query names this file declares.
# test/e2e_login.sh drives it; the other examples hold 8080-8085 and 8091-8098, so this service takes 8086.
server "login", version: "0.1.0"
set :port, 8086
set :rust, :none

# The key every cookie is signed with: at least 32 bytes, or the server exits with status 2 as it starts.
setting :secret_key, env: "SECRET_KEY_BASE", secret: true
cookies secret: :secret_key

# A write from another site (a browser's Sec-Fetch-Site says so) answers 403; curl and servers pass.
use_layer :fetch_metadata

# Rails' rate limit on login, the compiler's own fixed-window limiter: at most `burst:` requests to the one
# path in any `per:` seconds, counted per client address (the same address request_ip reads), past which the
# answer is 429 "rate limit exceeded". Without `path:` every route would be counted. test/e2e_login.sh
# bursts /session at the end of its first run, after the login assertions it must not disturb.
use_layer :rate_limit, per: 60, burst: 25, path: "/session"

database :sqlite, path: "login.sqlite3", env: "DATABASE_PATH"
migrations "login/db/migrate"

record :User do
  field :id, :i64
  field :name, :string
  field :email_address, :string
  field :password_digest, :string
end

query :user_by_email, args: { email: :string }, returns: :User?, sql: <<~SQL
  SELECT id, name, email_address, password_digest FROM users WHERE email_address = :email
SQL

query :user_for_session, args: { token: :string }, returns: :User?, sql: <<~SQL
  SELECT users.id AS id, users.name AS name, users.email_address AS email_address, users.password_digest AS password_digest
  FROM users JOIN sessions ON sessions.user_id = users.id WHERE sessions.token = :token
SQL

execute :add_user, args: { name: :string, email: :string, digest: :string }, sql: <<~SQL
  INSERT INTO users (name, email_address, password_digest) VALUES (:name, :email, :digest)
SQL

execute :start_session, args: { token: :string, user_id: :i64, ip: :string, agent: :string }, sql: <<~SQL
  INSERT INTO sessions (user_id, token, user_agent, ip_address, last_active_at)
  VALUES (:user_id, :token, :agent, :ip, datetime('now'))
SQL

execute :end_session, args: { token: :string }, sql: "DELETE FROM sessions WHERE token = :token"

# The signed-in user, computed the first time a route or filter reads it and kept for the rest of the request.
# The cookie reads as nil when it is absent or its signature does not verify.
current :user, returns: :User? do
  token = cookie(:session_token)
  token.nil? ? nil : user_for_session(token: token)
end

params :Signup do
  field :name, :string, in: :form
  field :email, :string, in: :form
  field :password, :string, in: :form
end

params :Login do
  field :email, :string, in: :form
  field :password, :string, in: :form
end

get "/session/new", description: "The login form" do
  html("<form method='post' action='/session'><input name='email'><input name='password' type='password'><button>Log in</button></form>")
end

post "/signup", params: :Signup, description: "Create a user; the password is stored as a bcrypt digest" do
  return halt(409, "that email address is taken") unless user_by_email(email: params[:email]).nil?
  added = add_user(name: params[:name], email: params[:email], digest: Bcrypt.hash(params[:password]))
  return halt(500, "the user was not added") if added != 1
  redirect("/session/new")
end

# A session is a row holding a random token; the cookie holds that token, signed. A browser sends the logout
# below as fetch(..., { method: "DELETE" }), since a form cannot, so the logout is a DELETE and not a form post.
post "/session", params: :Login, description: "Log in: start a session and set the session_token cookie" do
  user = user_by_email(email: params[:email])
  return halt(401, "bad login") if user.nil? || !Bcrypt.verify(params[:password], user.password_digest)
  token = random_token
  started = start_session(token: token, user_id: user.id, ip: request_ip, agent: user_agent)
  return halt(500, "the session was not started") if started != 1
  set_cookie :session_token, token, http_only: true, same_site: :lax, permanent: true
  redirect("/me")
end

get "/me", description: "The signed-in user's name, or a redirect to the login form" do
  user = current(:user)
  return redirect("/session/new") if user.nil?
  "Hello, #{user.name}"
end

delete "/session", description: "Log out: delete the session row and the cookie" do
  token = cookie(:session_token)
  return redirect("/session/new") if token.nil?
  ended = end_session(token: token)
  delete_cookie :session_token
  redirect("/session/new?ended=#{ended}")
end
