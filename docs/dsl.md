# The DSL

Declaring an axum service: its crate, its params groups, its routes and its filters.

_See also: [README](../README.md)._

## How to declare a service

```ruby
# typed: true
server "notekit", version: "0.1.0"
set :port, 8080

params :SearchParams do
  field :query, :string, in: :query, description: "Words to look for", min_length: 1, max_length: 40
  field :limit, :i32, in: :query, optional: true, min: 1, max: 50
  field :kind, :string, in: :query, optional: true, enum: ["all", "recent", "pinned"]
  field :tag, :string, in: :query, optional: true, pattern: "^[a-z][a-z0-9-]*$"
end

get "/search", params: :SearchParams, description: "Search the notes" do
  json(params[:limit] || 10)
end

before do
  content_type(:json)
end
```

- **The shape is Sinatra's.** `server` and the routes sit at the top level; there is no enclosing block.
  A file names its crate with `server "name", version: "0.1.0"` (or `set :name`/`set :version`) and must
  name both, or the compiler refuses the file. `set :port, 8080` and `set :bind, "0.0.0.0"` configure the
  listener (Sinatra's own defaults: 127.0.0.1:4567). `set :listener, "tls::TlsListener"` binds a Rust
  type from a `rust_file` in place of the TCP listener, which is the hook for TLS; `set :log, :json` (or
  `:text`, the default) picks the log format (see [Deploying the emitted crate](cli.md#deploying-the-emitted-crate)).
- **Routes** are `get`/`post`/`put`/`patch`/`delete`/`options`/`head` with a path, an optional
  `params:` naming a params group, an optional `description:`, and a required block — the body language.
  A path uses Sinatra's `:name` capture syntax (`"/users/:id"`), translated to axum 0.8's `{name}`; axum
  has no optional segments and no patterns beyond one named capture, so anything else is refused. The
  last expression of the block is the response.
- **Fields** take `description:`, `optional:`, `default:`, and JSON schema constraints: `min:`/`max:` and
  `exclusive_min:`/`exclusive_max:`/`multiple_of:` on numbers, `min_length:`/`max_length:`/`pattern:`/`enum:`
  on strings, `min_items:`/`max_items:` on lists. The generated service also enforces the constraints and
  answers a violation with a 400, because a schema on its own is only advice. An optional field is
  nil-able in the body (`params[:limit] || 10`); a field with a `default:` is always present. A form
  field may add `name: "message[body]"` for a Rails-style bracketed wire key: the generated struct field
  and `params[:body]` keep the DSL name, so the `Form` extractor reads the bracketed key while `check()`
  and `errors` stay keyed by the DSL name. `name:` is refused on anything but `in: :form`, and two fields
  of a group may not share a wire key. **A params group is the typed allowlist** — this language's strong
  parameters: the declared fields are the accepted inputs, and every other key in the query, form or JSON
  body is ignored (serde's default), like Rails' `permit` dropping unpermitted keys. There is no
  `require(:name)` envelope and no dynamic `permit`; a missing or mistyped declared field is axum's 422,
  and a constraint violation is the generated `check()`'s 400.
- **`in:`** says which part of the request a field arrives in: `:path`, `:query`, `:body` or `:form`. It
  is optional except for `:form`, and the verb decides the default (`:body` for post/put/patch, `:query`
  for get/delete/head/options). A group whose fields arrive in more than one part needs `in:` on each. A
  body is read as JSON (the `json` feature is on in the emitted Cargo.toml); a path capture is parsed at
  the field's type. `:form` reads an `application/x-www-form-urlencoded` body with axum's `Form`
  extractor, which is what an HTML form POST sends: it is always written out, it belongs to
  post/put/patch only (a browser sends a form body on no other verb), and a group cannot mix `:body` and
  `:form`, because axum lets one extractor consume the body. A urlencoded body is flat key/value pairs,
  so a form field is a scalar; a list or a nested object belongs in a JSON body. A body the `Form` extractor cannot deserialize at all (a missing field, or a value of the wrong shape) is answered by axum itself with 422, where a value that parses but breaks a constraint is the 400 the generated `check()` gives. A Rails form's bracketed key (`message[body]`) is a `name:` on the field, not a nested form object: the URL-encoded body stays flat, and the wire key is the one the extractor reads.
- **Field types** are `:string :i32 :i64 :f64 :bool`, lists (`:string_list`, `:i64_list`, `:f64_list`,
  also written `list(:string)`, `list(:i64)`, `list(:f64)`), typed maps with string keys and one value
  type (`map(:i64)`, `map(:string)`, `map(:f64)`, `map(:bool)`, `map(list(:string))`, `map(map(:i64))`),
  a list of objects (`list(:Address)`), and a nested object: name another `params` declared above
  (`field :address, :Address`) and read it in the body as `address.city`; an `optional: true` object is
  read nil-safely as `address&.city`. `format:` (`:uri :email :date_time :date :uuid :hostname :ipv4
  :ipv6`) is advice to the client and is not checked by the service. A map is a Rust `BTreeMap`, so keys
  come back sorted, and maps are read-only.
- **Response helpers.** `text(s)` and `html(s)` answer a string (the first as `text/plain`, the second
  as `text/html`); `json(value)` serialises the value as JSON; `redirect("/path")` answers a 302 Found
  (`redirect(path, status: 303)` names another redirect status: 301, 302, 303, 307 or 308); its path is
  a literal of visible ASCII (0x20-0x7E, or a tab) with no leading or trailing whitespace, or a literal
  interpolating only numbers and bools, because it becomes the `Location` header.
  A body may not combine `status(...)` with a helper's `status:`;
  `render :signup, locals: { ... }` answers with a view (see below and [Views](views.md)); and
  `halt(status, body)` stops with that status (or `halt(status)` with no body). They are values, so they
  can be the body's last expression. `text`, `html`, `json` and `render` also take `status: 401` and
  `content_type: "text/vnd.turbo-stream.html"` (a string literal), which ride on the returned value, so
  `return render(:x, status: 201, content_type: "text/html", locals: { ... })` keeps both; a body may not
  combine the `content_type(...)` statement with a helper's `content_type:`.
  `h(value)` escapes `&`, `<`, `>`, `"` and `'` and is what a page
  interpolates; `raw(value)` is the same value with no escaping, the XSS door a review greps for by name.
  Escaping is by value, not by context — a `javascript:` URL in an `href` survives `h`, and the body has no
  sanitiser; a view's `{{ name|sanitize }}` is the one, for HTML text (see [Views](views.md)). `status(201)` and
  `content_type(:json)` are statements, not values; `content_type` is only meaningful inside a `before`
  filter, where it is the default for the routes that follow. `headers "Cache-Control" => "no-store"` is a statement too: it puts
  header lines on the response (see [the body language](body-language.md)). A body that ends in a plain
  string is a 200 text response, which is Sinatra's rule.
- **Views.** `render :signup, locals: { name: params[:name] }` answers with a page: the `.html` file
  `views/signup.html` (`set :views` names the folder), read at compile time and compiled into the emitted
  Rust, so the crate carries no template and no `.html` file. A view holds exactly ten markers —
  `{{ name }}` (escaped), `{{ name|raw }}` (unescaped), `{{ name|sanitize }}` (HTML text cleaned, not
  escaped), `{{ yield }}` (the wrapped view's markup, in a layout),
  `{% raw %}…{% endraw %}` (copied byte for byte) and `{{ partial :name, key: value }}` (another
  view file, read at compile time and inlined; its markers read only its arguments, and its arguments are
  literals or the caller's locals), `{% for x in xs %}…{% endfor %}` (the text once for each element of a list
  local) and `{% if name %}…{% else %}…{% endif %}` (one of two branches, taken when the bool or nil-able
  `name` is true), `{{ csrf_token }}` (the token `use_layer :csrf` puts on the request, for a form's
  `authenticity_token`) and `{{ asset_path "campfire.css" }}` (the fingerprinted URL of a file under a
  `static ... digest: true` mount) — and the logic stays in the route body.
  `set :layout, :app` gives every render a layout, `render :x, layout: :other` overrides it and
  `layout: nil` opts out; `locals:` must name exactly the markers' names, minus `yield` (and the
  `{{ csrf_token }}`/`{{ asset_path ... }}` markers, which read no local). A page whose
  `{{ }}` belongs to a client framework (Vue, Handlebars, a `<template>` an SPA clones) is not a view but
  a static asset, because the browser evaluates the data inside the live template and HTML escaping cannot
  prevent it. See [Views](views.md).
- **Filters.** `before do ... end` runs for every route (a content type, a guard); a filter whose body ends in a
  response helper answers the request itself, and one that ends in a plain value passes it on. `before
  :authenticate do ... end` names the filter, and a route opts out with `skip: [:authenticate]`: the filter
  still layers the router, and the emitted layer compares the request's method and path with the skipping
  routes. A duplicate name, and a skip of a name no `before` declares, are refused. A skip that could also
  match a route, a `serve_file` or the OpenAPI document is refused. `current :user, returns:
  :User?, required: :authenticate` reads `current(:user)` at its non-nil type in routes that do not skip the
  filter, and refuses a route that skips it and still reads the current. `not_found do ... end` answers a
  request that matched no route (axum's fallback). `error do ... end` answers a route body that raised;
  without one, the raised message becomes a plain 500.
- **Middleware.** `use_layer :compression`, `use_layer :cors, origins: ["https://example.com"]`,
  `use_layer :timeout, secs: 5`, `use_layer :trace`, `use_layer :private_cache` (with its optional `except:` list) and
  `use_layer :rate_limit, per: 60, burst: 20, path: "/session"` wrap the whole router: gzip/deflate
  response compression, CORS, a request timeout,
  `tracing`-based request logging (`:trace` installs the log subscriber, so it prints at the default `info`
  level; `RUST_LOG` overrides), the compiler's own fixed-window rate limiter, and `:private_cache`'s
  header append. A
  layer answers every route, so where the declaration sits in the file does not change the service; the
  compiler puts them on the router in its own fixed order and adds each tower-http feature
  (`compression-gzip`, `cors`, `timeout`, `trace`) to the one `tower-http` line, alongside `fs` when a
  file service needs it. `:cors` without `origins:` is permissive; `:timeout` needs `secs:`, a positive
  whole number of seconds. `use_layer :trace, forwarded: true` logs the visitor's `X-Forwarded-For`
  address instead of the peer's (see [Deploying the emitted crate](cli.md#deploying-the-emitted-crate)).
  `:rate_limit` needs a positive `per:` (the window in seconds) and `burst:` (requests per window);
  `path:` counts one exact path, and without it every route is counted. Past the burst the answer is 429
  `rate limit exceeded`, counted per client address (the same address `request_ip` reads). The map is
  process-wide and uses only std: no crate, and a restart clears it. The window is fixed and anchored to
  the epoch, so a client can spend `burst:` at the end of one window and again at the start of the next;
  there is no `Retry-After` header, the map never evicts (a client can add a key per address), and with
  `forwarded: true` the key is the caller's `X-Forwarded-For` entry, so trust it only behind a proxy that
  overwrites that header.
  `use_layer :private_cache` appends `Cache-Control: private, no-cache` and `Vary: Cookie` to every
  response by default, never inserted, so a route's own `Cache-Control` is kept beside them; that is what
  stops a shared cache from storing an authenticated page. Its one keyword is `except:`, an explicit list
  of literal path prefixes served by a declared `static` mount — `use_layer :private_cache, except:
  ["/assets"]` — which leave the layer off. `except:` may not name `/`, a route, or a path no mount
  serves, so a page with a session or a CSRF token cannot be exempted by accident. Exempting a mount
  removes the private headers but adds no public `Cache-Control`, and ServeFile still answers
  Last-Modified/If-Modified-Since 304s. It is the compiler's own middleware with no tower-http feature,
  and it sits outside `:csrf`, `:fetch_metadata` and `:rate_limit`, so a refusal or a 429 from any of
  them carries the headers too.
  `:csrf` takes no keywords: it needs `cookies secret:`, and it refuses a write (anything but GET, HEAD
  and OPTIONS) whose `authenticity_token` field or `X-CSRF-Token` header does not match the signed
  `_axum_dsl_csrf` cookie, with 403; `use_layer :fetch_metadata` stays the first-line guard outside it
  (see [Sessions](sessions.md)).
  A name may be declared once: a second `use_layer :compression` is refused.
- **Helpers.** `helper :name, args: [:string], returns: :string do |text| ... end` declares a typed
  function that route bodies and later helpers call by name; types are always written out and a helper
  may only call helpers declared above it. Keyword parameters are `kw: { limit: [:i32, false] }` with a
  literal default in the block. A helper that nothing calls is refused. See
  [The body language](body-language.md).
- **Settings** are values the service reads from its environment when it starts:
  `setting :base_url, env: "API_URL", default: "https://api.example.com"`, `setting :token, env:
  "API_TOKEN", secret: true`, also `optional: true`, `description:` and `type:`. A route or a filter body
  reads one with `setting(:token)`; a helper or a binding body cannot (see [Coverage](coverage.md)). A
  `setting` cannot configure the listener, because a `set` value is a literal.
- **SQL state** is `database :sqlite, path: "...", env: "..."`, `record`, `query` and `execute` with `:name`
  placeholders, and a `migrations` folder; a route or a filter body calls a statement as
  `name(arg: value)` and may group those calls in `transaction do ... end`. The SQL runs as written. See
  [Database](database.md).
- **Sessions** are the compiler's own, with no app Rust: `cookies secret: :secret_key, format: :hmac` signs
  cookies (`format: :rails` writes Rails' classic MessageVerifier value and `:rails7` the JSON/`_rails`
  value a default Rails 7/8 app reads), bodies read one with `cookie(:name)` (or
  `signed: false` for a plain one) and a route writes one with `set_cookie` / `delete_cookie`;
  `random_token`, `request_ip`, `user_agent`; `current :user, returns: :User? do ... end`, a per-request value
  read with `current(:user)`; the built-in `Bcrypt.verify` / `Bcrypt.hash`; `use_layer :fetch_metadata`, which
  answers 403 to a cross-site write; `use_layer :csrf`, the signed-token check behind it (it needs
  `cookies secret:`); and `set :rust, :none`, which refuses every declaration that injects
  Rust. See [Sessions](sessions.md).
- **Bindings** (`use_bindings :name`) load `bindings/NAME.rb`, found next to the DSL file, so bodies call
  its typed functions as `Module.method`. See [Bindings](bindings.md).
- **Splitting a service into files.** `use_dsl "dsl/routes.axum.rb"` reads a fragment, a file whose one
  top-level call is `fragment do ... end`, and treats its declarations as if they were written at that
  line, so declaration order runs across files. A fragment holds what a file holds. Paths are relative to
  the file that says `use_dsl`, and stay inside the server file's folder; no file is included twice. An
  error names the fragment's own file and line. Build the file, not a fragment. A `render` in a fragment reads
  views from the server file's folder (the `set :views` folder beside the file being built), not beside the
  fragment; every other relative path still resolves beside the fragment that names it. A split written for
  the earlier fragment-relative rule must move its `views/` folder beside the server file (see [Views](views.md)).
- **Injected Rust and files.** `rust_crate "heck", "0.5"` adds a Cargo dependency; `rust_item <<~'RS'
  ... RS` injects Rust; `rust_fn :name, args: ..., returns: ...` declares its signature (a body calls it
  as `rust(:name, ...)`); `rust_file "rust/x.rs", as: :x` brings in a `.rs` file as a module;
  `cmd_fn`/`script_fn` run a subprocess; `file "python/x.py", as: :x` names a file bodies read with
  `file_text(:x)`; it is copied into the crate at that path and read from the working directory (or from
  `env:`), so editing the source needs a rebuild. See [Bindings](bindings.md).
- **Serving files.** `static "/assets", dir: "public"` mounts a directory at a path prefix; a named `before`
  filter covers it like a route, so `static "/assets", dir: "public", skip: [:authenticate]` keeps the
  directory public (GET of the prefix and its subtree): every request
  under the prefix is answered by tower-http's `ServeDir`, which guesses each file's content type from its
  extension, answers a request for a directory as its `index.html`, and answers an empty 404 for a missing
  file and for a path segment holding `..` or a backslash. A mount at `/` is axum's fallback rather than a
  prefix, so it cannot take `skip:`: that skip would cover every GET path, and the compiler refuses it;
  mount at a prefix instead. `serve_file` and `set :public_folder` take no `skip:` today.
  `serve_file "/report.txt", from:
  "public/report.txt"` answers one route with one file. `set :public_folder, "public"` is the same mount
  at `/`, which is Sinatra's meaning for the setting; a `not_found` filter cannot go with it, because both
  claim axum's one fallback. A body-level `send_file` is refused: it would have to await a file service,
  and no response helper does. The declared path is **copied into the emitted crate** at the same relative
  path, and the emitted `ServeDir::new("public")` resolves it against the process's working directory: a
  built service must run with the crate directory as its working directory (that is what
  `test/e2e_assets.sh` sets up, and what `axum_dsl build` + `axum_dsl run` produce in their `-o`
  directory). A path outside the DSL file's folder, or a symlink that leaves the declared directory, is
  refused, as is a route whose path sits under a mount prefix (axum would panic on the overlap).
  `digest: true` copies each file under `<stem>-<twelve hex digits of its SHA-256><ext>` and serves only
  that name, so a far-future `Cache-Control` is safe and the undigested path is a 404; a view writes the
  URL with `{{ asset_path "campfire.css" }}` (see [Views](views.md)).
- **An API document.** `openapi "/openapi.json"` makes the service answer `GET` at that path with an OpenAPI
  3.1 document the compiler wrote from the routes: each route is an operation (its `description:` is the
  summary), path and query fields are parameters, body and form fields are the request body, and a field's
  `description:` and constraints become JSON Schema keywords. `title:` and `version:` default to the server's
  name and version. Without the declaration, `description:` stays in the IR only. See [OpenAPI](openapi.md).


## What is refused, and why

`after do ... end` (axum has no filter that runs after a handler has built its response; only `before`
has an equivalent), `erb`/`haml` (Sinatra renders a Tilt template at run time, and the extension picks its
engine; a view here is a `.html` file the compiler reads, so the extension is the escaping context and a
template format of its own is not a view — see [Views](views.md)), `configure do ... end` (a service has no environment
concept; `set` configures), `development?`/`production?` (nothing compiled is conditional on the
environment), and a path with `?` or an inline regex (axum's router has only one named capture).
`helpers do ... def ... end` (Sinatra's Ruby helpers) is deliberately not implemented: the typed
`helper` form gives the same thing with checkable signatures.

A second `use_layer` of the same name is refused, as is a `use_layer` whose keyword does not belong to
that layer, an origin that is not a plain origin, a `:timeout` with no positive `secs:`, a `:rate_limit`
with no positive `per:` or `burst:`, and a `:private_cache` `except:` that is empty, malformed, lists a
prefix twice, is `/`, or names a path no `static` mount serves. A group
that mixes `in: :body` and `in: :form` is refused, because axum lets one extractor consume the body, and
`in: :form` on a route whose verb is not post/put/patch is refused, because a browser sends a form body
on no other verb.
