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
  `params:` naming a params group, an optional `description:`, and a block — the body language. A route in a
  controller may instead name `action:` and use that controller's `def` as its body; a route outside a
  controller may name `controller:` and `action:` (a routes file). A route with neither a block nor `action:` is
  refused.
  A path uses Sinatra's `:name` capture syntax (`"/users/:id"`), translated to axum 0.8's `{name}`; axum
  has no optional segments and no patterns beyond one named capture, so anything else is refused. The
  last expression of the block is the response.
- **Resources and scopes.** `resources :rooms, only: %i[show edit], params: :RoomPath` declares Rails'
  resource routes at `/rooms`, each reaching the controller's matching `def` (`controller:` names a
  different controller); `cache:` applies to every generated route, `description:` and `params:` to every route
  or, as a hash by action (`description: { index: "Chat bots", new: "New chat bot" }`, `params: { edit: :BotPath,
  create: :BotForm }`), to the ones it names (a hash group reaches `create` too), and `update`
  answers PATCH and PUT. A member route captures `:id`, which is derived from the table of the model declared with `table: :rooms`
  (see Path params below); without such a model `show`/`edit`/`update`/`destroy` need a
  `params:` group with an `id` field `in: :path`. The resource declares `rooms_path`, `room_path(id)`,
  `new_room_path`, `edit_room_path(id)` and their `_url` forms. `scope path: "rooms/opens" do ... end`
  prefixes the routes in its block, and blocks nest. Nested `resources` are not implemented yet, and
  `create`/`update` take a form group only through an explicit route (Track RB4).
- **Path params of a resource are derived** (Track RR6). `resources :rooms` captures `:id` on its member routes; the
  type is the `id` (primary key) column of the table of the model declared `model :Room, table: :rooms`. Nothing is read
  from the URL or guessed from a plural: the resource name is the table name, unless `model:` names the model
  (`resources :bots, model: :User` for the bots, which are rows of `users`; `namespace :rooms do resources :opens, model: :Room end`
  in Rails). Each derived capture is a node of the type graph, `param:GET /rooms/:id.id`, taking its type from
  `column:rooms.id` by the rule `resources :rooms`. A route with no `params:` gets a group of its
  own (`RoomsMemberPath`); a group given with `params:` gets the `id` field in front when it does not declare one. A declared
  `id` field of another type is refused, naming both sources; one that repeats the derivation gets the notice
  `N-PATH-PARAM-DERIVED` (the line can go unless another route uses the group). Where the compiler is asked for types
  (`check --types`) the derived field carries `rooms.id via resources :rooms`. Nested resources and explicit
  `get "/x/:id"` routes are not derived yet and keep their declared fields.
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
  so a form field is a scalar, a list of scalars (Rails' repeated `name[]` keys, below) or an `:upload`; a map or a nested object belongs in a JSON body. A body the `Form` extractor cannot deserialize at all (a missing field, or a value of the wrong shape) is answered by axum itself with 422, where a value that parses but breaks a constraint is the 400 the generated `check()` gives. A Rails form's bracketed key (`message[body]`) is a `name:` on the field, not a nested form object: the URL-encoded body stays flat, and the wire key is the one the extractor reads. A group with an `:upload` field also reads a `multipart/form-data` body (see Uploads below).
- **Field types** are `:string :i32 :i64 :f64 :bool`, lists (`:string_list`, `:i64_list`, `:f64_list`,
  also written `list(:string)`, `list(:i64)`, `list(:f64)`), typed maps with string keys and one value
  type (`map(:i64)`, `map(:string)`, `map(:f64)`, `map(:bool)`, `map(list(:string))`, `map(map(:i64))`),
  a list of objects (`list(:Address)`), and a nested object: name another `params` declared above
  (`field :address, :Address`) and read it in the body as `address.city`; an `optional: true` object is
  read nil-safely as `address&.city`. `format:` (`:uri :email :date_time :date :uuid :hostname :ipv4
  :ipv6`) is advice to the client and is not checked by the service. A map is a Rust `BTreeMap`, so keys
  come back sorted, and maps are read-only. `:upload` is a file chosen in a browser form (see Uploads below):
  `in: :form` only, always nil-able, no constraints.
- **Uploads** (`multipart/form-data`, what a form with a file input sends even when no file is chosen). A group that
  has an `:upload` field reads its form the way Rack does: a urlencoded body exactly as before, a multipart body as
  its text parts (into the group's other `in: :form` fields, bracketed `name:` keys included; a repeated name keeps
  its last value) and its file parts (into the `:upload` fields by `name:`, else by field name). A group with neither
  an `:upload` nor a list field keeps axum's `Form` and answers a multipart body 415.
  **Rails' merged params.** `set :merge_query_params, true` reads a form field the body lacks from the query string,
  as Rails' `params` is `query_parameters.merge(request_parameters)`: a key the body carries is the body's alone (a list
  included), and an empty or missing body leaves the query's pairs. It applies to every `in: :form` group, urlencoded or
  multipart; without it a form field reads the body only.
  **Repeated keys.** A `:string_list`, `:i64_list` or `:f64_list` field `in: :form` (`field :user_ids, list(:i64),
  in: :form, name: "user_ids[]", default: []`) collects every occurrence of its key, in order, from a urlencoded
  or a multipart body, as Rack does for `name[]`: `user_ids[]=1&user_ids[]=2` is `[1, 2]`. A value that does not
  parse as the element type is 422. When the key is absent the field is its `default:` (`[]` is Rails'
  `params.fetch(:user_ids, [])`), nil when `optional: true`, else 422. A key that is not a list keeps its last
  value when repeated, as Rack does (axum's own `Form` would refuse a repeat). A group with a list field reads
  its urlencoded body with the same code as a multipart one (2 MiB, else 413). A file input nobody chose a file in sends a
  part with an empty filename; Rack drops it, so the field is nil, as is a missing one. The whole body is held in
  memory (128 MiB, else 413), at most 4096 parts and 128 files (413), and a body that is not well formed is 400.
  In the body the field is an object with `filename`, `content_type` (Active Storage's identified type:
  `Marcel::MimeType.for(first 4 KB, name:, declared_type:)` with Marcel 1.1's whole magic, extension and parent tables, so
  a JPEG sent as `application/octet-stream` is `image/jpeg`), `size` (bytes), `checksum` (Active Storage's: the base64
  MD5) and `metadata` (the blob's analyzed JSON: `{"identified":true,"width":W,"height":H,"analyzed":true}` for a JPEG,
  PNG, GIF, WebP, TIFF or simple SVG, read from its header and swapped for the EXIF orientations ImageAnalyzer::Vips
  swaps; `{"identified":true,"analyzed":true}` otherwise; fuzzed against Rails in Campfire's
  `test/differential/fuzz_identify`), read like a nested object (`avatar&.filename`, or `unless avatar.nil?` on a local first), and
  `avatar.store(root)` writes the file the way Active Storage's Disk service does: under a new 28-character lowercase
  base36 key, at `<root>/<key[0,2]>/<key[2,2]>/<key>`, and gives the key back. The `active_storage_blobs` and
  `active_storage_attachments` rows are the app's own `execute` statements (`key`, `filename`, `content_type`,
  `byte_size: avatar.size`, `checksum: avatar.checksum`), in a `transaction` if they must go together; `store` is an
  `await` that fails the request (the `error` filter, else 500) when the write fails. No width or height is read from
  an image and no variant is made. `examples/upload.axum.rb` is a complete service; `Upload` cannot name a params group.
- **Response helpers.** `text(s)` and `html(s)` answer a string (the first as `text/plain`, the second
  as `text/html`); `json(value)` serialises the value as JSON; `redirect("/path")` answers a 302 Found
  (`redirect(path, status: 303)` names another redirect status: 301, 302, 303, 307 or 308); its path is
  a literal of visible ASCII (0x20-0x7E, or a tab) with no leading or trailing whitespace, or a literal
  interpolating only numbers, bools or a `url_encode(...)` call, because it becomes the `Location` header. In a route, a `before`
  or a `current` body, a path starting with `/` is written as an absolute URL, as Rails' `redirect_to`
  does: the request's scheme and host (`request_base_url`, which trusts `X-Forwarded-Host`/`-Proto` only
  under `use_layer :trace, forwarded: true`) in front of the path. The response has an empty body and `Content-Type: text/html; charset=utf-8`, as Rails' `redirect_to` does.
  A body may not combine `status(...)` with a helper's `status:`;
  `render :signup, locals: { ... }` answers with a view (see below and [Views](views.md)); and
  `halt(status, body)` stops with that status (or `halt(status)` with no body); `head(status)` is Rails'
  `head :forbidden` from an action: an empty `text/html` response that `:rack_defaults` still refreshes the
  session cookies on, even for a 4xx. They are values, so they
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
  Rust, so the crate carries no template and no `.html` file. A view holds exactly twelve markers —
  `{{ name }}` (escaped), `{{ name|raw }}` (unescaped), `{{ name|sanitize }}` (HTML text cleaned, not
  escaped), `{{ yield }}` (the wrapped view's markup, in a layout), `{{ yield :nav }}` and
  `{% content_for :nav %}…{% endcontent_for %}` (a layout's named region and the page's fill for it),
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
  match a route, a `serve_file` that does not skip it or the OpenAPI document is refused. `current :user, returns:
  :User?, required: :authenticate` reads `current(:user)` at its non-nil type in routes that do not skip the
  filter, and refuses a route that skips it and still reads the current. `not_found do ... end` answers a
  request that matched no route (axum's fallback); `not_found skip: [:authenticate] do ... end` lets such a request
  bypass the named filters, as Rails routes a request before any controller filter (an unknown path is a 404 even
  signed out). `error do ... end` answers a route body that raised;
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
  `path:` counts one exact path, and without it every route is counted; `enabled: :name` names a declared
  integer setting read on each request, and 0 lets every request through (Rails' `rate_limit` on a `:null_store`
  cache, as in its test environment). A layer counts before every filter; where Rails' callbacks before its
  `rate_limit` (a ban check, say) must decide first, uncounted, use the `rate_limited?("name", to:, within:)` check in
  a filter or route body instead (it renders whatever rejection the app writes). Past the burst the answer is 429
  `rate limit exceeded`, counted per client address (the same address `request_ip` reads). The map is
  process-wide and uses only std: no crate, and a restart clears it. The window is fixed and anchored to
  the epoch, so a client can spend `burst:` at the end of one window and again at the start of the next;
  there is no `Retry-After` header, the map never evicts (a client can add a key per address), and with
  `forwarded: true` the key is the caller's `X-Forwarded-For` entry, so trust it only behind a proxy that
  overwrites that header.
  `use_layer :private_cache` appends `Cache-Control: private, no-cache` and `Vary: Cookie` to every
  response by default, never inserted, so a route's own `Cache-Control` is kept beside them (unless it says `public`: then the route keeps its policy and gets neither header); that is what
  stops a shared cache from storing an authenticated page. Its one keyword is `except:`, an explicit list
  of literal path prefixes served by a declared `static` mount — `use_layer :private_cache, except:
  ["/assets"]` — which leave the layer off. `except:` may not name `/`, a route, or a path no mount
  serves, so a page with a session or a CSRF token cannot be exempted by accident. Exempting a mount
  removes the private headers but adds no public `Cache-Control`, and ServeFile still answers
  Last-Modified/If-Modified-Since 304s. It is the compiler's own middleware with no tower-http feature,
  and it sits outside `:csrf`, `:fetch_metadata` and `:rate_limit`, so a refusal or a 429 from any of
  them carries the headers too.
  `use_layer :rack_defaults` is what Rails' default middleware stack does to the HTML a route renders, one
  keyword per part (at least one is needed): `security_headers: true` sets Rails 8's five default headers
  (`X-Frame-Options: SAMEORIGIN`, `X-XSS-Protection: 0`, `X-Content-Type-Options: nosniff`,
  `X-Permitted-Cross-Domain-Policies: none`, `Referrer-Policy: strict-origin-when-cross-origin`) on every
  response, whatever its type, that has none of its own, except a Live one: a route that writes
  `headers "X-Rack-Defaults" => "live"` (Rails' ActionController::Live controllers, such as an avatar's
  `send_file`, which skip `default_headers`) gets none; `"unauthenticated"` (an action under Rails'
  `allow_unauthenticated_access`, which never resumes the session) leaves the `refresh_cookies` unwritten; the
  marker is removed before the response leaves.
  `halt(204, "")` (also 205 and 304) sends no `Content-Type`, as Rails' `head :no_content` does. `version: :app_version` and
  `revision: :git_revision` name declared settings written as `X-Version` and `X-Rev` (an empty revision writes
  none, and both still apply to a file response); `etag: true` is Rack::ETag (a weak ETag over a 200 HTML,
  Turbo Stream or JSON GET's body unless the route set one, 304 for a matching `If-None-Match`, and, when the route
  set no `Cache-Control`, `max-age=0, private, must-revalidate` for a response with an ETag and `no-cache` for
  one without; the validator is a std hash, not SHA-256, and a body over 16 MiB answers 500);
  `vary_accept: true` adds `Vary: Accept` to a successful response whose format came from the `Accept` header
  (an `Accept` with no `*/*` entry, as Turbo frame fetches send, or any `Accept` on an XHR; not when the URL
  has a `format` parameter or a file extension); `preload: ["campfire.css"]` lists files of the one
  `static ..., digest: true` mount in a `Link: <url>; rel=preload; as=style; nopush` header on a full layout
  (a body starting `<!doctype html`; a turbo-frame fragment does not get it);
  `refresh_cookies: ["session_token"]` writes a cookie the request carried again (twenty years, HttpOnly,
  SameSite=Lax) when the response did not set it, and `session_cookie: "_app_session"` writes a plain HttpOnly
  SameSite=Lax cookie on a response that does not carry it; both skip a 4xx/5xx answer and a redirect to
  `/session/new`. `except:` leaves the layer off a declared `static` mount, as for `:private_cache`. The layer
  is innermost, so it sees the body before `:compression` encodes it; a refusal from `:csrf`,
  `:fetch_metadata` or `:rate_limit` does not pass through it. Declare it instead of `:private_cache` when the
  service wants Rails' headers: the two both write `Cache-Control`.
  `use_layer :method_override` is Rack::MethodOverride: a POST whose urlencoded body has a `_method` field, or whose
  multipart/form-data body has a `_method` text part (the last one either way), else whose `X-HTTP-Method-Override` header is set, is routed as that method when it, upcased, is
  GET, HEAD, PUT, POST, DELETE, OPTIONS, PATCH, LINK or UNLINK (anything else stays a POST), so a Rails-style
  form (`method="post"` plus a hidden `_method=delete`) reaches the `delete` route. The body is read once
  (a urlencoded body over 2 MiB, or a multipart one over 128 MiB, is a 413) and passed on unchanged, `_method`
  included; a multipart body that does not parse is left to the route (400) and the header is read. It takes no keywords. Unlike the other
  layers it wraps the finished router rather than being a `.layer(..)` on it, because axum's `Router::layer`
  runs after the route is matched: it is outside every other layer, so `:csrf` and `:fetch_metadata` see the
  rewritten method (a `DELETE` is still a write), and `:trace` logs it.
  `use_layer :format_extension` is Rails' optional `(.:format)` on every route: a path whose last segment ends in an
  extension, that no route, static mount or served file answers as sent (a segment capture takes no `.`, as in Rails)
  but a route answers without the extension, is routed without it, with `format=<format>` added to the query (a params
  field `format` reads it); for `.turbo_stream`, `.json`, `.html`, `.js`, `.xml`, `.csv`, `.txt` and the other Rails
  Mime type extensions the format's MIME type becomes the Accept header, so the format wins over Accept as in Rails. A route declared with the extension (`/feed.json`) is left alone.
  It takes no keywords, and it wraps the finished router as `:method_override` does.
  `use_layer :front` is what Rack::Deflater and Thruster (the proxy in front of a Rails app) do to every
  response, as one middleware outside all the others but `:trace` (so `:rack_defaults`' ETag is over the identity
  body). It gzips a response for a client whose `Accept-Encoding` allows gzip, whatever its size or type (not
  1xx/204/304, `no-transform`, an already-encoded response, an event stream or an upgrade), sets
  `Content-Encoding: gzip`, drops `Accept-Ranges`, and adds `accept-encoding` to `Vary` after the app's own
  tokens (`accept, accept-encoding`). Thruster's cache keeps a GET/HEAD response that says `public` with a
  `max-age` above 0 (and no `no-cache`) in memory until it expires, and answers a request with the same method,
  path, query, host and `Vary`ing headers from it with `X-Cache: hit` (a 304 when `If-None-Match` names its
  ETag); the first response is `X-Cache: miss`, and a request that cannot be cached (not GET/HEAD, an
  upgrade, a `Range`, a URI over 2048 bytes) goes through with `X-Cache: bypass`. `enabled: :name` names a declared integer setting, read on
  each request: 0 answers without the front (no deflate, cache or Date), as Rails' test environment answers
  without Thruster. `cache_mb:` is the cache's
  size (64; 0 turns it off); a response over 1 MB is not kept, and when the cache is full the entries nearest
  their expiry go first. Not carried over from Thruster: zstd and the BREACH padding. A gzipped response is
  buffered whole (up to 64 MiB). It adds the `flate2` crate.
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
- **Controllers.** `controller "Accounts::Bots" do ... end` groups routes with their own `before :def, only:/except:`
  filters and `def` methods, expanded inline where they are called (a `return` in one answers the request). Top-level
  defs are shared by every route. See [Controllers](controllers.md).
- **Laws.** `law :name, forall: :Params, cases: 256 do |a, b| <bool> end` is a property over a params group's
  fields, generated within their constraints, compiled to a seeded proptest test that `axum_dsl test FILE` runs. See
  [Laws](laws.md).
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
  `random_token`, `request_ip`, `request_base_url`, `request_path`, `request_query`, `request_method`, `user_agent`, `request_referrer`, `turbo_frame_request?`, `turbo_stream_request?`
  (`set :trust_forwarded_for, true` makes `request_ip` read `X-Forwarded-For` without the trace layer); `current :user, returns: :User? do ... end`, a per-request value
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
- **Response cache.** `get "/rooms/:id", cache: :private do ... end` keeps the whole response of a GET route in
  memory until the next database commit (a read-only SQLite connection watches `PRAGMA data_version`) or 15
  seconds, per request URI and headers, so per session. The `before` filters still run on every request and the
  route body is skipped on a hit (its writes and `set_cookie` too); an `etag(...)` still answers 304. The size
  is `setting :response_cache_mb, env: "...", default: 64, type: :i64` (64 MB without the setting, 0 off). With
  `use_layer :front`, a client that accepts gzip has its entry stored already compressed at admission; a hit
  skips the deflater, and `Accept-Encoding` is part of the key, so gzip and identity entries are separate. It
  needs `database :sqlite`, is for `get` only, and refuses a body that calls `random_token`, `send_file`,
  `file_text`, `request_ip`, `rust(...)` or a subprocess function. It is not `use_layer :private_cache`, which
  only appends `Cache-Control: private, no-cache` and `Vary: Cookie` and stores nothing.
- **Serving files.** `static "/assets", dir: "public"` mounts a directory at a path prefix; a named `before`
  filter covers it like a route, so `static "/assets", dir: "public", skip: [:authenticate]` keeps the
  directory public (GET of the prefix and its subtree): every request
  under the prefix is answered by tower-http's `ServeDir`, which guesses each file's content type from its
  extension, answers a request for a directory as its `index.html`, and answers an empty 404 for a missing
  file and for a path segment holding `..` or a backslash. A mount at `/` is axum's fallback rather than a
  prefix, so it cannot take `skip:`: that skip would cover every GET path, and the compiler refuses it;
  mount at a prefix instead. `set :public_folder` takes no `skip:` today.
  `serve_file "/report.txt", from:
  "public/report.txt"` answers one route with one file; `skip: [:authenticate]` on it keeps the file public like a
  route's does (GET and HEAD of that path). `set :public_folder, "public"` is the same mount
  at `/`, which is Sinatra's meaning for the setting; a `not_found` filter cannot go with it, because both
  claim axum's one fallback. A body-level `send_file` is refused: it would have to await a file service,
  and no response helper does. The declared path is **copied into the emitted crate** at the same relative
  path, and the emitted `ServeDir::new("public")` resolves it against the process's working directory: a
  built service must run with the crate directory as its working directory (that is what
  `test/e2e_assets.sh` sets up, and what `axum_dsl build` + `axum_dsl run` produce in their `-o`
  directory). A path outside the DSL file's folder, or a symlink that leaves the declared directory, is
  refused, as is a route whose path sits under a mount prefix (axum would panic on the overlap).
  `digest: true` copies each file under `<stem>-<8 hex digits><ext>` and serves only that name (without
  `Accept-Ranges`), so a far-future `Cache-Control` is safe and the undigested path is a 404. The digits are
  Propshaft's: the first 8 of SHA-1 over the file's bytes, then the bytes of every file its CSS refers to with
  `url(...)` or `@import url(...)` (depth first, once each), then `version:` ("1.0" by default, Rails'
  `config.assets.version`), so `_reset.css` is `_reset-9c3efd7b.css` as in Rails; those references in the served
  CSS become the digested URLs (`url("/assets/base-53e48027.css")`), and one that names no file of the mount
  (`data:`, `http`, `//`, `#`) is left alone. `max_age: 2592000` adds `Cache-Control: max-age=2592000, public`
  to the mount's successful responses that have none. A view writes the URL with
  `{{ asset_path "campfire.css" }}` (see [Views](views.md)).
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
