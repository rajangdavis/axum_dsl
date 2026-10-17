# Sessions

_See also: [README](../README.md), [The DSL](dsl.md), [The body language](body-language.md), [Database](database.md), [Coverage](coverage.md)._

A service can sign people in without a line of Rust of the app's own. Cookies, session tokens, password
hashing, a per-request "current user" and a cross-site guard are the compiler's: each is Rust it writes into
the emitted crate, only when the file uses it. `examples/login.axum.rb` is the worked example (it is shaped
like Campfire's login: a `sessions` table, a random token, a signed cookie holding the token, logout that
deletes both), and `make e2e-login` drives it.

```ruby
setting :secret_key, env: "SECRET_KEY_BASE", secret: true
cookies secret: :secret_key                  # signs every cookie; format: :rails opts into Rails' value

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
load. `format:` is the wire format of the signed cookies: `:hmac` (the default) or `:rails` (below); a `cookie`
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
functions), and the cookie runtime around it is shared. The formats are `:hmac`, the default, and `:rails`.

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

This is the Marshal form: `MessageVerifier`'s own default serializer, and the cookie jar's when
`config.action_dispatch.cookies_serializer = :marshal`. Rails 4.1 and later default that to `:json`, and Rails 6
and later wrap purpose/expiry metadata around the value when `use_cookies_with_metadata` is on, so a cookie from
a default modern Rails app is not read yet. To interoperate, the app needs
`cookies_serializer = :marshal`, `use_cookies_with_metadata = false`, and a key generator on SHA1 (Rails
before 7.0, or `config.active_support.key_generator_hash_digest_class = OpenSSL::Digest::SHA1`); Rails 7.0's
framework defaults change that digest to SHA256, which this format does not derive yet. Even then the payload
must be a UTF-8 `String`: a Rails signed cookie holding an Integer, Array, Hash or a US-ASCII/ASCII-8BIT
String reads as absent.

The cookie header is parsed by the emitted code (no cookie crate). The crates are `hmac` 0.12, `sha2` 0.10 and
`base64` 0.22 for `:hmac`; `hmac` 0.12, `sha1` 0.10, `pbkdf2` 0.12 and `base64` 0.22 for `:rails`; and none for a
service that only reads or writes plain cookies. They are added only when a body uses them.

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

`before` filters apply to every route (there is no path scoping today), so a `before` that redirects when
`current(:user)` is nil would redirect the login page too; the example checks in the routes that need a user.

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
  the hmac format even when the service's other cookies declare `format: :rails`.
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
  (`Cache-Control: private, no-store`): a cached form would hand one token to every visitor, and the token is
  not per-session to make that harmless. A per-user or per-session token means managing the cookie and the
  hidden field together in the route; `{{ csrf_token }}` always writes the layer's token. A token written
  with percent-escapes is decoded as a form value, so an encoder's `%2D` still matches.


## `set :rust, :none`

A strict mode: the file takes no Rust of its own. The compiler refuses, at the line, everything that injects
app Rust: `rust_item`, `rust_fn`, `rust_file`, `set :listener` (it needs a `rust_file`), and a `use_bindings`
whose called functions are backed by a Rust template. Bindings compiled from Ruby, `cmd_fn` and `script_fn` stay.
The setting may be written after the declaration it refuses. Without it nothing changes.

## What is not here

- Rails' cookies beyond the Marshal `MessageVerifier` form: the `:json` cookie serializer and Rails 6+ purpose/expiry
  metadata, and the SHA256 key derivation of Rails 7+ defaults.
- Encrypted cookies. A cookie is signed unless `signed: false`, and none is encrypted.
- Session expiry and cleanup, "remember me" lifetimes beyond `permanent:` and `max_age:`, and password rules: a
  session is a row the app's own SQL manages.
- Path scoping for `before` filters: a filter runs for every route, and a `before` cannot be limited to a path yet.
- Setting cookies from a `before` filter or a `current`, and from a route that returns early.
