# Sessions

_See also: [README](../README.md), [The DSL](dsl.md), [The body language](body-language.md), [Database](database.md), [Coverage](coverage.md)._

A service can sign people in without a line of Rust of the app's own. Cookies, session tokens, password
hashing, a per-request "current user" and a cross-site guard are the compiler's: each is Rust it writes into
the emitted crate, only when the file uses it. `examples/login.axum.rb` is the worked example (it is shaped
like Campfire's login: a `sessions` table, a random token, a signed cookie holding the token, logout that
deletes both), and `make e2e-login` drives it.

```ruby
setting :secret_key, env: "SECRET_KEY_BASE", secret: true
cookies secret: :secret_key                  # signs every cookie; format: :rails or :rails7 picks the Rails value

current :user, returns: :User? do            # a per-request value, computed at most once, on first use
  token = cookie(:session_token)             # :string?, nil when absent or the signature does not verify
  token.nil? ? nil : user_for_session(token: token)
end

post "/session", params: :Login do
  user = user_by_email(email: params[:email])
  return halt(401, "bad login") if user.nil? || !Bcrypt.verify(params[:password], user.password_digest)
  token = random_token
  started = start_session(token: token, user_id: user.id, ip: request_ip, agent: user_agent)
  return halt(500, "the session was not started") if started != 1
  set_cookie :session_token, token, http_only: true, same_site: :lax, permanent: true
  redirect("/me")
end

use_layer :fetch_metadata
set :rust, :none
```

## Cookies

`cookies secret: :setting_name, format: :hmac` names a `setting` and is declared once per file; every cookie
call needs it. The setting must be a required string (not `optional: true`, not a `type:`), and a `default:`
shorter than 32 bytes is refused when the file is compiled. The value is read as the server starts: a key
shorter than 32 bytes stops the server with a message on stderr and exit status 2, like a setting that cannot
load. `format:` is the wire format of the signed cookies: `:hmac` (the default), `:rails` or `:rails7` (both below); a `cookie`
or `set_cookie` call may give `format:` to use the other one for that cookie.

- `cookie(:name)` is a `:string?`: the cookie's value, or nil when the cookie is absent, malformed or its
  signature does not verify. A route, a `before` filter or a `current` body may read one.
- `cookie(:name, signed: false)` is the plain cookie's value, or nil when it is absent. It is not signed and no
  key is consulted; `format:` is refused with `signed: false`, since there is no signature to format.
- `set_cookie :name, value, http_only: true, same_site: :lax, secure: false, permanent: false, max_age: nil,
  signed: true, format: nil` is a statement of a route body, like `headers`. The keywords are literals and the
  values above are the defaults. `same_site:` is `:lax`, `:strict` or `:none`. `permanent: true` is a `Max-Age`
  of twenty years, as in Rails (631139040 seconds); `max_age:` is a number of seconds; give one of them, and a
  cookie with neither is a session cookie. The path is always `/`.
- `set_cookie :name, value, signed: false` writes a plain cookie: `name=value`, no MAC (the need is Rails'
  `last_room`). A plain cookie's value is percent-encoded as Rack encodes a cookie and decoded when read, so
  `Room 1` travels as `Room+1`; a signed `:hmac` value is base64url and needs no escaping.
- `delete_cookie :name` is a statement of a route body that tells the browser to drop the cookie (`Max-Age=0`).

A `set_cookie` or `delete_cookie` goes on the response the route ends in, as `status` and `headers` do: they are
statements of a route body, so a `return` earlier in the body (`return halt(401)` included) answers without the cookies set before it.

The signed forms are behind a seam, `AxumDsl::Cookies` (`lib/axum_dsl/cookies.rb`), the way the SQLite backend is
behind `Db`: a format is a module with `deps` (its Cargo.toml lines) and `items` (its `sign` and `verify`
functions), and the cookie runtime around it is shared. The formats are `:hmac`, the default, `:rails` and `:rails7`.

- `:hmac` is `<base64url(value)>.<base64url(HMAC-SHA256(secret, name + "=" + value))>`, no padding, the MAC
  compared in constant time. The name is part of what is signed, so a value cannot be moved to another cookie.
- `:rails` is Rails' `ActiveSupport::MessageVerifier` value with the Marshal serializer:
  `Base64.strict_encode64(Marshal.dump(value)) + "--" + OpenSSL::HMAC.hexdigest(OpenSSL::Digest::SHA1.new, key,
  data)`, where `data` is the Base64 text and the digest is lower-case hex. Rails 8.0's
  `activesupport/lib/active_support/message_verifier.rb` is the source: `SEPARATOR` is `"--"`, `encode` is
  `Base64.strict_encode64` and `generate_digest` is `OpenSSL::HMAC.hexdigest`. The key is
  `ActiveSupport::KeyGenerator#generate_key("signed cookie", 64)`:
  `OpenSSL::PKCS5.pbkdf2_hmac(SECRET_KEY_BASE, "signed cookie", 1000, 64, OpenSSL::Digest::SHA1.new)`, with
  `Rails.application.key_generator`'s `KeyGenerator.new(secret_key_base, iterations: 1000)`
  (`railties/lib/rails/application.rb`) and PBKDF2-HMAC-SHA1 as
  `activesupport/lib/active_support/key_generator.rb`'s digest class default, with the default key size of 64
  bytes, the signed jar's salt from `actionpack/lib/action_dispatch/middleware/cookies.rb`, and its
  `"signed cookie"` default from
  `actionpack/lib/action_dispatch/railtie.rb`. Rails does not sign the cookie's name, so a Rails-signed value can
  be moved between cookie names; that is Rails' format, not one this compiler can change. A `:rails` value is
  percent-encoded in `Set-Cookie` as Rack encodes it (`URI.encode_www_form_component`), and decoded before
  verification.
- `:rails7` is the signed cookie a default Rails 7.0+ or 8.x application writes: the cookie jar's `:json`
  serializer, the `_rails` metadata envelope, and Rails 7.0's key derivation. `value` is
  `JSON.generate(value)` (a JSON String), whose Base64 is the envelope's `message`:
  `{"_rails":{"message":<Base64>,"exp":<null or ISO8601 string>,"pur":"cookie.<name>"}}` (`pur` is set
  because `use_cookies_with_metadata` is on since Rails 6.0). `exp` is null for a cookie with no lifetime,
  and a UTC ISO8601 string for `permanent: true`/`max_age:`: `Messages::Metadata.pick_expiry` writes
  `expires_at.utc.iso8601(3)`, e.g. `"3018-07-11T16:11:26.753Z"` (three fractional digits);
  `CookieJar#cookie_metadata` passes only `:expires`, so `permanent:` is `20.years.from_now` in that form.
  The HTTP `Max-Age` the browser honours is separate. Rails' own `max_age` alone writes `exp: null`; this
  compiler's `max_age:` writes the same instant as its `Max-Age`, valid to Rails and tighter.
  The envelope's Base64 is `data`, and the digest is
  `OpenSSL::HMAC.hexdigest("SHA1", key, data)` in lower-case hex, joined to it by `"--"` exactly as for
  `:rails`. The key is `ActiveSupport::KeyGenerator#generate_key("signed cookie", 64)`, i.e.
  `OpenSSL::PKCS5.pbkdf2_hmac(SECRET_KEY_BASE, "signed cookie", 1000, 64, OpenSSL::Digest::SHA256.new)`
  under `load_defaults "7.0"`, whose `key_generator_hash_digest_class` is `OpenSSL::Digest::SHA256`
  (`railties/lib/rails/application/configuration.rb`, `railties/lib/rails/application.rb`,
  `activesupport/lib/active_support/key_generator.rb`); the verifier's own digest is still the signed
  jar's `signed_cookie_digest`, `"SHA1"` by default
  (`actionpack/lib/action_dispatch/middleware/cookies.rb`, `message_verifier.rb`). The envelope keeps its
  legacy shape even on Rails 7.1+, because the cookie verifier's serializer is
  `ActiveSupport::MessageEncryptor::NullSerializer`, which is not in `Metadata::ENVELOPE_SERIALIZERS`
  (`activesupport/lib/active_support/messages/metadata.rb`). A cookie written with
  `use_cookies_with_metadata = false` (the JSON text signed directly) is read too. A non-null `exp` must
  be a string strictly later than the current time: `parse_expiry` leaves a non-String unchanged and
  `Time.iso8601` parses the string, so Rails would raise on an integer. It is checked after the signature
  as `Messages::Metadata#verify` does; an expired, malformed or integer `exp` reads as absent, and since
  the metadata is signed a changed `exp` cannot pass the MAC. The payload must be a JSON String: an Integer,
  Array or Hash reads as absent. `:rails7` is percent-encoded in `Set-Cookie` and decoded before
  verification, as `:rails` is.

`:rails` is the Marshal form: `MessageVerifier`'s own default serializer, and the cookie jar's when
`config.action_dispatch.cookies_serializer = :marshal`. It interoperates with a Rails app before 7.0, or one
that sets `cookies_serializer = :marshal`, `use_cookies_with_metadata = false`, and
`config.active_support.key_generator_hash_digest_class = OpenSSL::Digest::SHA1`. A default Rails 7.0+ or
8.x app uses `:rails7`: `load_defaults "7.0"` selects `cookies_serializer = :json` and the SHA256 key
derivation, and `load_defaults "6.0"` turns metadata on. A Rails 7 app still on `load_defaults "6.1"`
keeps the SHA1 key derivation: set
`config.active_support.key_generator_hash_digest_class = OpenSSL::Digest::SHA256`, or use `:rails`. In both
forms the payload must be a UTF-8 `String`: a Rails signed cookie holding an Integer, Array, Hash or a
US-ASCII/ASCII-8BIT String reads as absent. Neither form is encrypted; `:rails7` reads only a JSON String
and enforces a non-null metadata `exp`, which the signature protects.

The cookie header is parsed by the emitted code (no cookie crate). The crates are `hmac` 0.12, `sha2` 0.10 and
`base64` 0.22 for `:hmac`; `hmac` 0.12, `sha1` 0.10, `pbkdf2` 0.12 and `base64` 0.22 for `:rails`; `hmac`
0.12, `sha1` 0.10, `sha2` 0.10, `pbkdf2` 0.12 and `base64` 0.22 for `:rails7`; and none for a service that
only reads or writes plain cookies. They are added only when a body uses them.

## Rails signed IDs

`rails_signed_id(token, purpose: "user/avatar", secret: :secret_key)` verifies a Rails 8
`ActiveRecord::Base#signed_id` value without the Rails gems, and returns its integer id (`nil` for any
failure). Rails 8.2's `signed_id_verifier` is `ActiveRecord.message_verifiers["active_record/signed_id"]`:
the key is `ActiveSupport::KeyGenerator#generate_key("active_record/signed_id", 64)` over SECRET_KEY_BASE
(PBKDF2-HMAC-SHA256, 1000 iterations), derived once per process as Rails does; every call must name the same
`secret:` setting, and a second different one is refused. The verifier's options are
digest SHA256, serializer JSON and
`url_safe: true` (`activerecord/lib/active_record/signed_id.rb`,
`activerecord/lib/active_record/railtie.rb`, `railties/lib/rails/application.rb`). The payload is the
`_rails` metadata envelope `{"_rails":{"data":<id>,"pur":"<model>/<purpose>"}}`; a token is its URL-safe
Base64 without padding, `"--"`, and the lower-case hex HMAC-SHA256 of that text. The purpose is the full
`"user/avatar"` string: `signed_id(purpose: :avatar)` on User composes it in
`combine_signed_id_purposes`, so the caller passes the Rails string rather than a model name. Signature,
purpose and the integer payload are checked in that order; a non-string `data`, a missing envelope, a bad
MAC or a wrong purpose is nil. An `exp` in the envelope is refused in this version: an expiring token is
safe to reject, while accepting it without checking the expiry would not be. The crates are `hmac` 0.12,
`sha2` 0.10, `pbkdf2` 0.12 and `base64` 0.22, added only when a body calls the verifier.

## Values: `random_token`, `request_ip`, `user_agent`

- `random_token` is a string of 24 characters from the base58 alphabet Rails' `has_secure_token` uses
  (`123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz`), drawn from `rand` 0.9's thread generator, which
  is seeded by the operating system.
- `request_ip` is the client address: the peer's. With `use_layer :trace, forwarded: true`, which already says a
  proxy is trusted, the first `X-Forwarded-For` entry comes first, as in that layer's log line.
- `user_agent` is the `User-Agent` header, empty when the request has none.

`request_ip` and `user_agent` read the request, so they are for route, `before` and `current` bodies; a helper or
a binding computes from its arguments, and `not_found` and `error` run without the request.

## `current`

`current :user, returns: :User? do ... end` declares a value that belongs to one request. The block is a body like
a route's without `params`: it may call queries, `cookie`, `request_ip`, helpers, and the `current`s declared above
it. A route or a `before` filter reads it with `current(:user)`; a helper cannot. `returns:` is what a query's
`returns:` is (`:Record?`, `list(:Record)` or a scalar).

It is computed at most once per request, on the first read, however many filters and the route read it: the
compiler adds a layer, outside every `before` filter, that gives each request an `Arc` of `OnceCell`s in its
extensions, and each read is `get_or_try_init` on the cell (tokio's `sync` feature is added then). An error in the
block behaves like a `raise` in the body that read it. A `current` nothing reads is a compile error.

## Named `before` filters, `skip:` and `required:`

A `before` filter runs for every route, as a router layer. Give it a name and a route can opt out:

```ruby
before :authenticate do
  return redirect("/session/new") if current(:user).nil?
  "continue"
end

get "/session/new", skip: [:authenticate] do
  render :session_new
end

get "/rooms/lobby" do
  # here current(:user) is a User, not a User?
  render :room
end
```

`before do ... end` stays the anonymous filter. A duplicate name is refused. `skip:` is a list of names and
says which filters that route does not run; skipping a name no `before` declares is refused. The filter is
still a layer, so the skip list is matched at run time: the emitted middleware compares the request's method
and URI path with each route that skips it (a `{name}` segment in the route path matches a non-empty
segment, a `{*tail}` matches the rest).
Because a router layer runs before axum has chosen a route, a skip that could also match a route which does
not skip the filter (`get "/rooms/:id"` beside a literal `get "/rooms/me"`, a `serve_file`, or the OpenAPI
document) is refused at compile time. The
comparison is on the raw request path, so a percent-encoded literal segment is not decoded: the skip then
fails closed and the filter still runs, as it does for the implicit HEAD of a `get` route. Only the named
filter steps aside; every other filter still runs, and the layers keep the order the emitter writes them in
(a later declaration wraps an earlier one). A `static` mount takes the same `skip:` list, and its emitted
entries are GET of the mount path and of its subtree (`/assets` and `/assets/{*path}`). A mount at `/` is
axum's fallback rather than a prefix, so its entries would cover every GET path and a skip there would
step the filter aside for every GET route: the compiler refuses that skip; mount at a prefix instead. `serve_file` and `set :public_folder` take no
`skip:` today.

`current ... required: :authenticate` links a nil-able current to the named filter that establishes it:

```ruby
current :user, returns: :User?, required: :authenticate do
  token = cookie(:session_token)
  token.nil? ? nil : user_for_session(token: token)
end
```

The named filter must exist, and its body must read `current(:user)` — that is what lets it stop a request
whose value is nil. A route that does not skip the filter reads the current at its non-nil type (`User`), with
no `nil?`/`||`; a route that skips the filter and reads it is refused at compile time. The emitted read is
still safe: if the contract is broken at run time it fails like a `raise` (a 500), never an `unwrap`. A filter
body, a `current` body and any other filter keep the nil-able type, so the guard can still be written.

## `Bcrypt`

`Bcrypt.verify(plain, digest)` is a bool: false for a digest that does not parse, never an error.
`Bcrypt.hash(plain)` is a string at cost 12, Rails' default. Both run under `tokio::task::spawn_blocking`, since
bcrypt is CPU-heavy, so a body that calls one is async. It is a compiler built-in, so it needs no `use_bindings`;
`Bcrypt.anything_else` is refused, and a binding may not take the module name. The crate is `bcrypt` 0.17.

## `use_layer :fetch_metadata`

For a method other than GET, HEAD and OPTIONS, a request whose `Sec-Fetch-Site` is present and is neither
`same-origin` nor `none` is answered 403 `cross-site request refused`. A request without the header (curl, a
server) passes. It takes no keywords and no tower-http feature. `use_layer :csrf` is the token check this
guard sits in front of (below).

## `use_layer :private_cache`

`use_layer :private_cache` needs no tower-http feature. It appends (it never replaces) two headers to every
response by default: `Cache-Control: private, no-cache` and `Vary: Cookie`. A page that carries a CSRF
token or a signed session must not be stored by a shared cache: `private` keeps it out of one, `no-cache`
makes a browser cache revalidate, and `Vary: Cookie` keys anything that is kept on the session. Because the
headers are appended, a route's own `Cache-Control` (an `ETag`d page's `max-age=60`, say) and `Vary` survive
beside them. The layer sits outside `fetch_metadata`, `csrf` and `rate_limit`, so their 403 and 429 answers
carry the headers too. For a form page whose token must never be reused from a cache at all, a route can add
`headers "Cache-Control" => "private, no-store"`; the layer leaves it in place.

Its one keyword is `except:`, an explicit list of literal path prefixes that leave the layer off:
`use_layer :private_cache, except: ["/assets"]`. Each prefix must be served by a declared `static` mount —
the mount's own prefix, or a path inside it at a segment boundary — and `/`, a route's path, or a prefix no
mount serves is refused, because only public files may leave the layer off. That is what keeps the default
safe: a page with a session or a CSRF token cannot be exempted by accident, and a mistyped prefix stops the
compile rather than quietly caching a login page. Exempting a mount removes the private headers but adds no
public `Cache-Control` of its own; a `serve_file` route is still tower-http's `ServeFile`, which answers
Last-Modified/If-Modified-Since 304s as before. A route can still add `private, no-store` (above).

## `use_layer :csrf`

`use_layer :csrf` is opt-in and needs `cookies secret: :setting_name`: the token is a signed cookie, so the
key and its 32-byte startup check are the cookie runtime's. It is the token check behind the Fetch Metadata
guard, and the two are meant to be used together: `use_layer :fetch_metadata` refuses an obvious cross-site
write before the body is read, and `:csrf` refuses a same-site-looking write that does not carry the token.
The emitter places `:fetch_metadata` outside `:csrf` for exactly that order.

- A safe request (GET, HEAD or OPTIONS) without a valid `_axum_dsl_csrf` cookie is given one: a
  24-character base58 token (the
  `random_token` runtime) in `<base64url(value)>.<base64url(HMAC-SHA256(key, name=value))>`, with
  `Path=/; SameSite=Lax; HttpOnly`, no `Secure` and no `Max-Age` (a session cookie). An unsafe request
  without a cookie is refused instead, and never gets one set on the 403. The token is signed with
  the hmac format even when the service's other cookies declare `format: :rails` or `:rails7`.
- A view writes it with `{{ csrf_token }}`, conventionally into a form's hidden field:
  `<input type="hidden" name="authenticity_token" value="{{ csrf_token }}">`. The marker is not a local, so
  `locals:` never names it; it reads the token the layer put in the request's extensions, and a route handler
  takes that extension only when a view it renders writes the marker.
- Every method but GET, HEAD and OPTIONS is checked. The submitted token is `X-CSRF-Token` when present,
  otherwise the `authenticity_token` field of an `application/x-www-form-urlencoded` body. That body is read
  once and rebuilt, so axum's `Form` extractor still sees the same bytes; a urlencoded write whose body is over
  2 MiB, read once to find the field, is a 413; a header write is not inspected by the layer. A
  missing or different token is 403 `CSRF token missing or invalid`, compared in constant time.
- The cookie is `HttpOnly`: the token travels in markup the server wrote, and no script needs to read it. A
  form POST is the checked shape; a JSON or `fetch` write must send `X-CSRF-Token`.
- Limits: one token lives as long as its cookie (no per-request rotation, no reset on login), and it is not
  bound to the user's session row. It is a double-submit token: the signature stops a forged cookie, but a
  sibling subdomain that can set a parent-domain cookie can plant a token it obtained from the same service,
  because nothing ties the token to the victim's session. The layer takes no keywords, so the emitted cookie
  is always `HttpOnly; SameSite=Lax`, never `Secure`, and a session cookie; a TLS deployment cannot mark it
  `Secure` through the layer. A page that carries `{{ csrf_token }}` must not be stored by a shared cache
  (`use_layer :private_cache` appends `Cache-Control: private, no-cache` and `Vary: Cookie`; a route can add
  `private, no-store` for a form that must never be reused from a cache): a cached form would hand one token
  to every visitor, and the token is not per-session to make that harmless. A per-user or per-session token means managing the cookie and the
  hidden field together in the route; `{{ csrf_token }}` always writes the layer's token. A token written
  with percent-escapes is decoded as a form value, so an encoder's `%2D` still matches.


## `set :rust, :none`

A strict mode: the file takes no Rust of its own. The compiler refuses, at the line, everything that injects
app Rust: `rust_item`, `rust_fn`, `rust_file`, `set :listener` (it needs a `rust_file`), and a `use_bindings`
whose called functions are backed by a Rust template. Bindings compiled from Ruby, `cmd_fn` and `script_fn` stay.
The setting may be written after the declaration it refuses. Without it nothing changes.

## What is not here

- Rails' encrypted cookies. A signed cookie's metadata expiry is enforced for `:rails7`, not refused:
  `permanent: true`/`max_age:` write the signed ISO8601 `exp`. `:rails` still has no metadata at all, so a value
  written for it carries no purpose or expiry.
- Encrypted cookies. A cookie is signed unless `signed: false`, and none is encrypted.
- Session expiry and cleanup, "remember me" lifetimes beyond `permanent:` and `max_age:`, and password rules: a
  session is a row the app's own SQL manages.
- Proving at compile time that a `required:` filter really stops every nil case: the compiler checks only that
  the filter reads the current (the run-time read is the safe fallback).
- Setting cookies from a `before` filter or a `current`, and from a route that returns early.
