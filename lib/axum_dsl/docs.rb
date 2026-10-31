# frozen_string_literal: true

module AxumDsl
  # One line of documentation for every DSL call and keyword, and the fixed choices of keywords whose
  # values come from a set the signature table's kinds cannot express. The generated skill and the
  # language server's hover and completion all read this, so a sentence is written once.
  # rmcp_dsl's test/test_dsl_completeness.rb (which fails when SIG gains a call or keyword with no
  # entry here, or when completion stops offering it) is not ported yet.
  module Docs
    # The route verbs share their keyword docs; each still gets its own line in CALLS.
    ROUTE_VERBS = %i[get post put patch delete options head].freeze

    # call name => what the call declares
    CALLS = {
      server: "Names the crate this file compiles to and pins its version; there is no block, because the routes are top level (Sinatra's shape).",
      set: "Sinatra's `set :name, value`: `:port` and `:bind` configure the listener, `:listener` names a Rust type from a rust_file that is bound in place of the TCP listener (the hook for TLS), `:log` is `:text` or `:json` and installs the log subscriber, `:trust_forwarded_for` makes `request_ip` read the first X-Forwarded-For entry without the trace layer (see docs/sessions.md), `:name` and `:version` are the crate's own metadata, `:public_folder` mounts a directory at \"/\", `:views`/`:layout` say where a body's `render` reads its views and which layout wraps them (see docs/views.md), and `set :rust, :none` refuses every declaration that injects Rust (see docs/sessions.md).",
      static: "Mounts a directory of files at a path prefix; tower-http ServeDir answers the requests, and the directory is copied into the generated crate. With `digest: true` each file is copied under `<stem>-<8 hex digits><ext>`, the digits Propshaft computes (only that name is served, without Accept-Ranges; a CSS file's `url(...)` names are rewritten to those names), and a view writes its URL with `{{ asset_path \"campfire.css\" }}`.",
      serve_file: "Answers one route with one file; the file is copied into the generated crate like a static mount.",
      cable: "An Action Cable endpoint: a WebSocket upgrade at the path that speaks the `actioncable-v1-json` protocol (welcome, a ping every 3 seconds, a confirmation or rejection for each subscribe), authenticated by the `current` named with `authenticate_with:`. A subscription listens on the broadcasting names its channel streams from, and `broadcast`, `broadcast_to` and `broadcast_turbo` in a route or a channel callback send to them (see docs/cable.md).",
      channel: "One channel a client may subscribe to, named as the client names it (`channel \"HeartbeatChannel\"`); a subscribe to any other name is rejected. `signed_stream:`, `room_param:` and `member_of:` say what the identifier must carry, and a block holds the channel's callbacks (`stream_from`, `stream_for`, `after_subscribe`, `on_unsubscribe`, `perform`). A `signed_stream:` channel streams from the verified stream name by itself.",
      stream_from: "Inside a `channel`: the broadcasting name the subscription listens to, as Rails' `stream_from \"user_\#{id}_reads\"`. The block ends in a string and names the values it wants as block parameters, `stream_from { |user| \"user_\#{user.id}_reads\" }`: the signed-in user (under the `current`'s name), `room_id` when the channel finds a room, and `room` (the row `member_of:` found).",
      stream_for: "Inside a `channel`: what the subscription listens to, as Rails' `stream_for @room`: the block ends in a string (a Global ID param for a record) and the broadcasting name is the channel's name underscored, a colon and that string (`typing_notifications:<gid param>`). `broadcast_to` in the channel's callbacks sends to it.",
      after_subscribe: "Inside a `channel`: runs once each time a subscription has been confirmed and has joined its streams; its block takes the same parameters as `stream_from`'s. It may call queries, `broadcast` and `broadcast_to`; its result and any error are ignored.",
      on_unsubscribe: "Inside a `channel`: runs when a client unsubscribes and for every subscription still held when its socket closes; its block may take the user and `room_id` and may call queries, `broadcast` and `broadcast_to`.",
      perform: "Inside a `channel`: `perform :start do |user| ... end` answers a client's `message` command whose `data` is `{\"action\":\"start\"}`, as a public method of the Rails channel does. An action the channel does not declare is dropped.",

      openapi: "Has the service answer GET at this path with an OpenAPI 3.1 document of its routes, written by the compiler from the routes, the params and their descriptions and constraints; nothing is generated at run time (see docs/openapi.md).",
      params: "A group of fields a route accepts, turned into a struct; a route names it with `params:` and reads it in the body with `params[:field]`.",
      field: "One field of a params group: a snake_case name and a type symbol such as :string or :i32, or `map(...)`/`list(...)`. An `in: :form` field may take `name: \"message[body]\"`, a Rails wire key that leaves the DSL name (and params[:body], check() and errors) unchanged. In a `record`, `list(:Other)` with `from: :a_query` is a list filled by that query, run once per row with the row's columns of the same names as its arguments (see docs/database.md).",
      use_layer: "Names a tower-http middleware the whole router is wrapped in (:compression, :cors, :timeout or :trace, which also installs a log subscriber, see `set :log`), or the compiler's own :fetch_metadata, which answers 403 to a cross-site write (see docs/sessions.md), :csrf, which checks a signed token on every write and answers 403 (it needs `cookies secret:`, see docs/sessions.md), and :rate_limit, the compiler's fixed-window limiter (`per:` seconds, `burst:` requests, optional `path:`, 429 past the burst, per request_ip), and :private_cache, which appends `Cache-Control: private, no-cache` and `Vary: Cookie` to every response so a shared cache does not store an authenticated page (a response whose own `Cache-Control` says `public` keeps it and gets neither header; its `except:` lists static mount prefixes that leave the layer off; only public files may be named), and :rack_defaults, Rails' default response headers for rendered HTML, one keyword per part: `security_headers:`, `version:`/`revision:`, `etag:`, `vary_accept:`, `preload:`, `refresh_cookies:` and `session_cookie:`, and :front, Rack::Deflater and Thruster in front of the app (gzip for a client that accepts it, `Vary: accept-encoding`, an in-memory cache of public max-age responses, and `X-Cache: hit/miss/bypass`; `cache_mb:` sizes the cache), and :method_override, Rack::MethodOverride (a POST whose `_method` form field, or X-HTTP-Method-Override header, names GET, HEAD, PUT, POST, DELETE, OPTIONS, PATCH, LINK or UNLINK is routed as that method, before :csrf and :fetch_metadata see it; a multipart body's `_method` text part is read too). A layer answers every route, so where it is written does not matter.",
      get: "A route that answers a GET request; the last expression of its block is the response, as text unless a helper says otherwise.",
      post: "A route that answers a POST request; its body may read a JSON body, a query string or a path parameter.",
      put: "A route that answers a PUT request; its body may read a JSON body, a query string or a path parameter.",
      patch: "A route that answers a PATCH request; its body may read a JSON body, a query string or a path parameter.",
      delete: "A route that answers a DELETE request.",
      options: "A route that answers an OPTIONS request.",
      head: "A route that answers a HEAD request.",
      before: "A filter that runs for every route, for what they all share (a content type, a guard). Name it (`before :authenticate do ... end`) so a route can skip it with `skip: [:authenticate]`; an unnamed filter runs for every route.",
      not_found: "What a request that matched no route answers with.",
      error: "What a route body that raised answers with; the value the body raised is the message.",
      helper: "A typed function that route bodies and later helpers can call by name; its argument and result types are written out.",
      setting: "A value the service reads from an environment variable when it starts; bodies read it with setting(:name).",
      cookies: "Names the setting every signed cookie is signed with, `cookies secret: :secret_key`, and its wire format: `format: :hmac` (the default), `:rails` (the classic Marshal MessageVerifier value) or `:rails7` (the JSON/`_rails` value a default Rails 7/8 app reads); bodies then read one with cookie(:name) (or cookie(:name, signed: false) for a plain one) and a route writes one with set_cookie and delete_cookie (see docs/sessions.md).",
      sanitizer: "A named HTML allowlist, `sanitizer :message_body, tags: %w[p a], attributes: %w[href class]`, that a view's `{{ body|sanitize :message_body }}` cleans a string with: exactly those tags and attributes (a tag that is not listed is dropped and its children kept), ammonia's URL checks, no tag or attribute that runs script (refused at compile time). `link_rel: false` stops ammonia adding `rel=\"noopener noreferrer\"`; `autolink_target: \"_blank\"` then links bare URLs and e-mail addresses as Rails' auto_link does (see docs/views.md). `attachments:` draws an opengraph embed with a view partial and `sounds:` draws a `/play NAME` body (see \"Attachments and sounds\" there).",
      current: "A per-request value, `current :user, returns: :User? do ... end`: computed on its first read in a request and kept for the rest of it; routes and filters read it with current(:user) (see docs/sessions.md). `required: :authenticate` names the `before` filter that establishes it, so a route that does not skip that filter reads it non-nil.",
      database: "The one database the service's queries run against: `database :sqlite, path: \"notes.sqlite3\", env: \"DATABASE_PATH\"`. :sqlite is the only adapter; the server opens it, applies the migrations and checks every query once as it starts (see docs/database.md).",
      migrations: "A folder of numbered *.sql files, relative to the DSL file, that the server applies once each, in file-name order, as it starts; they are embedded in the binary (see docs/database.md).",
      record: "The row a query returns: a CamelCase name and `field` lines with a scalar type (:string, :i64, :f64, :bool), `optional: true` for a column that may be NULL, or `list(:Other), from: :a_query` for a list of rows of another record that the query fills per row. A body reads it like a params object and `json(...)` writes it.",
      query: "A SQL statement that reads rows, run as written with `:name` placeholders bound from `args:`; it returns `list(:Record)`, `:Record?` (the first row or nil) or one scalar from the first row. A route or filter body calls it as `name(arg: value)`.",
      execute: "A SQL statement that changes data, run as written with `:name` placeholders bound from `args:`; a body calls it as `name(arg: value)` and gets the number of rows changed.",
      use_bindings: "Loads bindings/NAME.rb, found next to the DSL file, so bodies can call its typed functions as Module.method.",
      use_dsl: "Splices in the declarations of a fragment file, a path relative to this file, as if they were written at this line.",
      fragment: "The one top-level call of a file use_dsl includes; it holds the declarations a file holds.",
      rust_crate: "Adds a Cargo dependency (a crate name and a version) to the generated service for injected Rust.",
      rust_item: "Injects Rust source text into the generated crate unchecked; the compiler prints a notice for it.",
      rust_fn: "Declares a Rust function's argument and result types so bodies call it as `rust(:name, ...)`; the name is its name in the `from:` module.",
      rust_file: "Copies a hand-written .rs file from beside the DSL file into the crate as a module that rust_fn can point at.",
      file: "Loads a file from beside the DSL file that bodies read with file_text(:name) on each call; its entries are checked.",
      cmd_fn: "A function that runs a subprocess with fixed arguments and returns its output as a string; no shell is used.",
      script_fn: "A function that runs inline code in an interpreter such as python3 or ruby and returns its output as a string."
    }.freeze

    # [call name, keyword name] => what the keyword means. Route verbs share the `:route` entries.
    KEYWORDS = {
      %i[server version] => "The crate version as semver such as 0.1.0; it is written into the generated Cargo.toml.",

      %i[route params] => "The params group, declared above, that gives the route its fields; without it the route has no fields.",

      %i[static dir] => "The directory to serve, relative to the DSL file; its files are copied into the generated crate, so the running service finds them beside its own Cargo.toml.",
      %i[static digest] => "With true, copy and serve every file under a fingerprinted name (`campfire-<8 hex digits>.css`) instead of its own, so a far-future Cache-Control is safe. The digits are Propshaft's: the first 8 of SHA-1 over the file's bytes, then the bytes of every file its CSS refers to with `url(...)` or `@import url(...)` (depth first, once each), then `version:`; those references in the served CSS become the digested URLs. A view writes the URL with `{{ asset_path \"campfire.css\" }}`.",
      %i[static version] => "The assets version a `digest: true` mount hashes after the files (Rails' `config.assets.version`); \"1.0\" by default, which gives the names Rails serves. Changing it renames every file.",
      %i[static max_age] => "Seconds for `Cache-Control: max-age=N, public` on the mount's successful responses that have no Cache-Control of their own (Rails sends max-age=2592000 for assets).",
      %i[use_layer cache_mb] => "The size in megabytes of the response cache :front keeps (Thruster's CACHE_SIZE); 64 by default, 0 for no cache.",
      %i[serve_file skip] => "The named `before` filters this route does not run, such as `[:authenticate]`, as a route's `skip:` does (GET and HEAD of the file's path); skipping a name no `before` declares is refused.",
      %i[serve_file max_age] => "Seconds for `Cache-Control: max-age=N, public` on the file's successful responses that have no Cache-Control of their own (as `static` `max_age:`; Rails sends max-age=2592000 for public/ files).",
      %i[serve_file from] => "The file to serve, relative to the DSL file; it is copied into the generated crate the same way.",
      %i[cable authenticate_with] => "The `current` that says who is connecting, such as `:user` (a nil-able `current :user, returns: :User?`): it is read from the upgrade request's own headers, so it sees the session cookie as a route does, and a nil answers `disconnect` with reason `unauthorized` and closes the socket. A named `before` filter does not run for the endpoint.",
      %i[channel signed_stream] => "The required string setting that holds SECRET_KEY_BASE, the one a Turbo signed stream name is verified with, such as `:secret_key`: the identifier must carry a `signed_stream_name` that Turbo's verifier accepts, or the subscription is rejected.",
      %i[channel room_param] => "The identifier key that holds a room id, such as `:room_id` (a number or a numeric string); the subscription is rejected without it.",
      %i[channel member_of] => "A `query` taking `id:` and `user_id:` (both :i64) and returning `:Record?`: the subscription is rejected unless it finds a row for the room (from `room_param:`, or the Global ID inside the signed stream name) and the signed-in user.",
      %i[channel on_subscribe] => "An `execute` taking `room_id:` and `user_id:` (both :i64), run once for each confirmed subscription (never a rejected or repeated one); its result is ignored. Needs `member_of:`.",
      %i[rust_crate features] =>
 "The crate features to turn on, a non-empty list of strings such as [\"ring\"]; naming either keyword writes the dependency as a table in Cargo.toml.",
      %i[rust_crate default_features] => "With false, writes default-features = false, so only the crate's `features:` are on; true (the default) leaves the crate's own defaults.",
      %i[openapi title] => "The document's title; the server's name when left out.",
      %i[openapi version] => "The document's API version, any non-empty string; the server's version when left out.",
      %i[use_layer origins] => "The origins :cors allows, each a string such as \"https://example.com\"; without origins: the layer is permissive.",
      %i[use_layer secs] => "How long :timeout lets a request take, as a positive whole number of seconds.",
      %i[use_layer forwarded] => "With true, :trace logs the visitor's address from the first entry of X-Forwarded-For (else the peer's) and installs a log subscriber; trust it only behind a proxy that sets the header.",
      %i[use_layer security_headers] => "With true, :rack_defaults sets Rails 8's default headers on every response that has none of its own: X-Frame-Options SAMEORIGIN, X-XSS-Protection 0, X-Content-Type-Options nosniff, X-Permitted-Cross-Domain-Policies none and Referrer-Policy strict-origin-when-cross-origin; a route that writes `headers \"X-Rack-Defaults\" => \"live\"` (an ActionController::Live controller) gets none.",
      %i[use_layer version] => "The name of a declared setting :rack_defaults writes as the X-Version header on every response, such as `version: :app_version`.",
      %i[use_layer revision] => "The name of a declared setting :rack_defaults writes as the X-Rev header; an empty value writes no header.",
      %i[use_layer etag] => "With true, :rack_defaults does what Rack::ETag does: a 200 HTML GET gets a weak ETag from its body (unless the route set one), a matching If-None-Match answers 304, and a response with no Cache-Control gets `max-age=0, private, must-revalidate` when it has an ETag and `no-cache` when it has none.",
      %i[use_layer vary_accept] => "With true, :rack_defaults adds `Vary: Accept` to a successful response whose format came from the Accept header: an Accept that is not a browser's (no `*/*` entry), or any Accept on an XHR, and no `format` parameter or file extension in the URL.",
      %i[use_layer preload] => "Files of the one `static ..., digest: true` mount (such as \"campfire.css\") that :rack_defaults lists in a `Link: <url>; rel=preload; as=style; nopush` header on a full HTML page.",
      %i[use_layer refresh_cookies] => "Cookie names :rack_defaults writes again when the request carried them and the response did not set them (twenty years, HttpOnly, SameSite=Lax), as Rails does with a permanent session cookie on every response.",
      %i[use_layer session_cookie] => "The name of a plain HttpOnly SameSite=Lax session cookie :rack_defaults writes on a response that does not carry it, reusing the request's value or a fresh random token.",
      %i[use_layer except] => "Public static path prefixes that leave :private_cache or :rack_defaults off, each an exact `static` mount prefix or a path inside one (a segment boundary); only files a static mount serves may be named, and a route or a page with a session or CSRF token cannot be exempted. Without it the layer stays on every response.",
      %i[route description] => "What the route does; with an `openapi` declaration it becomes the operation's summary and description in the served document, and the service serves no API document without one.",
      %i[route skip] => "The named `before` filters this route does not run, such as `[:authenticate]`; the filter still layers the router, and it compares the request's method and path with the skipping routes. Skipping a name no `before` declares is refused.",
      %i[route cache] => "On a `get`: `cache: :private` keeps the whole response (status 200, at most 1 MiB, no `no-store`) in memory for the same request headers (Cookie included, so an entry belongs to one session), until the next database commit or 15 seconds, and answers a repeat from it with the route body skipped; the `before` filters and `required:` currents still run on every hit, and an `etag(...)` still answers 304. The budget is `setting :response_cache_mb, type: :i64` (64 MB when not declared, 0 turns it off). Needs `database :sqlite`, and a body that uses `random_token`, `send_file`, `file_text`, `request_ip`, `rust(...)` or a subprocess function is refused. It is not `use_layer :private_cache`, which only appends `Cache-Control: private, no-cache` and `Vary: Cookie` and stores nothing.",

      %i[field in] => "Which part of the request the field is read from: :path, :query, :body or :form (an HTML form body, read by axum's Form extractor; a group with an :upload field also reads a multipart/form-data body). The verb decides the default (body for post/put/patch, query otherwise); :form is always written out, and a route's fields may come from more than one part only if each says which.",
      %i[field description] => "What the field means; with an `openapi` declaration it is the description of the field's parameter or schema in the served document, and without one it is kept in the IR only.",
      %i[field optional] => "When true the caller may leave the field out and the body sees nil; it cannot be combined with `default:`.",
      %i[field default] => "The value used when the caller omits the field, within its other limits; a list field takes a literal list such as [] or [\"a\"].",
      %i[field min] => "The smallest allowed number; only for :i32, :i64 and :f64 fields, and an integer for the integer types.",
      %i[field max] => "The largest allowed number; only for :i32, :i64 and :f64 fields, and not below `min:`.",
      %i[field exclusive_min] => "The smallest allowed number, which the value must be above; only for :i32, :i64 and :f64 fields.",
      %i[field exclusive_max] => "The largest allowed number, which the value must be below; only for :i32, :i64 and :f64 fields.",
      %i[field multiple_of] => "The value must be a multiple of this positive number; only for :i32 and :i64 fields.",
      %i[field min_length] => "The fewest characters a :string field may have; the generated service enforces it.",
      %i[field max_length] => "The most characters a :string field may have; not below `min_length:`.",
      %i[field pattern] => "A regex a :string value must match: Ruby (Onigmo) source, translated to the Rust `regex` crate; the generated service enforces it.",
      %i[field enum] => "The only strings a :string field accepts: a non-empty list of distinct values.",
      %i[field format] => "A JSON schema format hint for a :string field, such as :email or :uri; it is advice to the client, not checked.",
      %i[field min_items] => "The fewest items a list field (:string_list, :i64_list or :f64_list, or list(:Name)) may have.",
      %i[field from] => "A record's list field only: the query (returning list of that record) that fills it, run once per row with the row's columns of the same names as arguments.",
      %i[field max_items] => "The most items a list field (:string_list, :i64_list or :f64_list, or list(:Name)) may have; not below `min_items:`.",

      %i[helper args] => "The argument types in order, such as [:string, :i64]; write them out, and use a trailing ? such as :string? for a nil-able parameter.",
      %i[helper kw] => "Keyword parameters a helper takes: a hash of `name: [type, required]`, declared after the positional ones and passed by name at the call site.",
      %i[helper returns] => "The result type; a trailing ? as in :string? means the helper may return nil.",
      %i[helper async] => "Not supported: async is inferred from the body, so `async: true` on helper is refused.",

      %i[setting env] => "The environment variable the value is read from; the service refuses to start when a required one is missing or empty.",
      %i[setting description] => "What the value is for, shown in the message when the service cannot start without it.",
      %i[setting default] => "The value used when the environment variable is not set, which makes the setting not required; a literal of the setting's type.",
      %i[setting optional] => "True when the service can run without the value; the body then gets the value or nil.",
      %i[setting secret] => "True for a key or token: a body can only pass it to a binding or rust_fn function, never print or return it.",
      %i[setting type] => "The value's type: :i64, :f64 or :bool, parsed when the service starts, which refuses to start on a value that does not parse. Text when left out.",

      %i[sanitizer tags] => "The tag names the sanitizer keeps, such as %w[p a strong]; any other tag is dropped and its children kept, so a wrapper tag left out unwraps. script, style, iframe, object, embed and similar tags are refused.",
      %i[sanitizer attributes] => "The attribute names kept on any allowed tag, such as %w[href src class] (Rails' safe-list takes attributes the same way, not per tag). URL attributes are still checked against ammonia's schemes; on* handlers, style, srcdoc and formaction are refused.",
      %i[sanitizer link_rel] => "`false` stops ammonia adding rel=\"noopener noreferrer\" to links, as Rails' sanitizer does not; `true` is the default, so it is not written.",
      %i[sanitizer autolink_target] => "After cleaning, link bare URLs and e-mail addresses outside tags and links (rails_autolink's auto_link with link: :all), with this `target`, such as \"_blank\".",
      %i[sanitizer attachments] => "Renders an <action-text-attachment> of a content type with a view partial: `{ \"application/vnd.actiontext.opengraph-embed\" => :opengraph_embed }`. The partial reads href, title, description, image, twitter_avatar, has_href and has_image; a `|sanitize` of this sanitizer then names the request host (`host: base_url`), which keeps a preview from pointing at this server. `\"application/vnd.campfire.mention\" => :mention` draws each mention of a user (an `<action-text-attachment sgid>`, whose sgid is decoded without checking its signature) with a partial reading id, name, title and version; `|sanitize` then also names the users, `{{ body|sanitize :message_body, host: base_url, mentions: users }}`, a list of records with those four fields. With both partials listed, `{{ body|editable :message_body, host: base_url, mentions: users }}` writes the editor's `value="..."` for a body from the same partials (Rails' `editable_body`, then Lexxy's JSON `content`). The SQL function `action_text_attachable_ids(html, 'User')` gives a query the ids a body names.",
      %i[sanitizer sounds] => "The sounds a body of exactly `/play NAME` plays: a name and its text (`\"bell\" => \"🔔\"`) or its image (`\"56k\" => [\"sounds/56k.webp\", 79, 33]`, a file under the digest mount and its width and height). The sound file is `NAME.mp3` under the same mount. A view tests it with `{% if body|sound :profile %}`.",
      %i[sanitizer sound_partials] => "The view partials that draw a sound, `{ text: :sound_with_text, image: :sound_with_image }`: the first reads url and text, the second url, src, width and height.",
      %i[cookies secret] => "The `setting` the cookies are signed with: a required string, at least 32 bytes when the server starts, or the server exits with status 2.",
      %i[cookies format] => "The signed cookies' wire format: `:hmac` (the default, `<base64url(value)>.<base64url(HMAC-SHA256(secret, name=value))>`) or `:rails` (Rails' ActiveSupport::MessageVerifier value with the Marshal serializer). A cookie call may override it with `format:`; a `signed: false` cookie has no signature and no format.",
      %i[current returns] => "What the value is: `:Record?` (the first row or nil), `list(:Record)` or a scalar type (:string, :i64, :f64, :bool, with ? for nil-able), as for a query.",
      %i[current required] => "The name of the `before` filter that establishes a nil-able current, such as `:authenticate`: a route that does not skip that filter reads current(:name) at its non-nil type, and a route that skips it and reads the current is refused.",

      %i[database path] => "The database file, relative to the directory the server runs in; with `env:` it is the fallback.",
      %i[database env] => "An environment variable that, when set and not empty, gives the database path instead of `path:`.",
      %i[query args] => "The query's arguments as a hash of name to scalar type, such as `{ limit: :i64 }`; every `:name` placeholder in the SQL needs one and every argument needs a placeholder.",
      %i[query returns] => "`list(:Record)` for every row, `:Record?` for the first row or nil, or a scalar type (:string, :i64, :f64, :bool, with ? for nil-able) read from the first column of the first row; a record's fields must be the columns the SQL selects.",
      %i[query sql] => "The SQL text, run exactly as written; use `:name` placeholders, not `?`, `$name` or `@name`.",
      %i[execute args] => "The statement's arguments as a hash of name to scalar type, such as `{ id: :i64 }`; every `:name` placeholder in the SQL needs one and every argument needs a placeholder.",
      %i[execute sql] => "The SQL text, run exactly as written; use `:name` placeholders, not `?`, `$name` or `@name`.",

      %i[rust_fn args] => "The argument types in order, such as [:string, :i32].",
      %i[rust_fn returns] => "The result type of the Rust function, as for a helper: `:string?` is an Option<String> the body must handle.",
      %i[rust_fn from] => "The `as:` name of the rust_file module that holds the function; leave it out for a function from rust_item.",
      %i[rust_fn async] => "True when the Rust function is async; a body that calls it awaits the eventual value.",

      %i[rust_file as] => "The module name the file gets in the crate, and the name `from:` refers to; it cannot be main or tests.",
      %i[rust_file uses] => "Set to :subprocess when the module starts subprocesses, so the generated crate includes the subprocess helper.",

      %i[file as] => "The name bodies use for the file, as in file_text(:name), entry(:name, :fn) and entry_args(:name, :fn, ...).",
      %i[file env] => "An environment variable that, when set, gives the path the running service reads the file from.",
      %i[file entries] => "The entries bodies name with entry(...); each needs a top-level, fully annotated definition in the file.",
      %i[file binary] => "true for a file that is not text (an image): it is copied into the crate and sent by file_path(:name), never read with file_text.",
      %i[file unchecked] => "Checks to turn off: :each_read (the running service re-checking entries) or :args (the entry_args comparison).",

      %i[cmd_fn program] => "The program to run, such as tr; only letters, digits and . _ + - / are allowed, and no shell is involved.",
      %i[cmd_fn argv] => "Fixed command line arguments placed before the call's own arguments, one list entry per argument.",
      %i[cmd_fn args] => "The types of the arguments the body passes, such as [:string]; they become extra arguments or stdin.",
      %i[cmd_fn returns] => "The result type; always :string, the program's standard output.",
      %i[cmd_fn pass] => "How arguments reach the program: :argv adds them to the command line (the default), :stdin writes one string to standard input.",
      %i[cmd_fn async] => "Not supported: a subprocess is blocking, so `async: true` on cmd_fn is refused.",

      %i[script_fn interpreter] => "The interpreter to run, such as python3, ruby, node, sh or bash.",
      %i[script_fn code] => "The source text that the interpreter runs; it receives the call's arguments as command line arguments.",
      %i[script_fn args] => "The types of the arguments the body passes, such as [:string].",
      %i[script_fn returns] => "The result type; always :string, the script's standard output.",
      %i[script_fn flag] => "The interpreter option that takes the code (such as -c); needed only for an interpreter the compiler does not know.",
      %i[script_fn async] => "Not supported: a subprocess is blocking, so `async: true` on script_fn is refused."
    }.freeze

    # [call name, keyword name] => the values the keyword accepts, when SIG's kind does not already list them
    CHOICES = {}.freeze

    # The body helper values: not declarations, so not in CALLS, but part of what a body may write. Each
    # entry is the call as it is written, then what it does, because their shapes differ: a value helper
    # takes one argument where render takes a view name and keywords. The generated skill's body page reads
    # this table.
    BODY_HELPERS = {
      h: "`h(value)` escapes a value for HTML (`&`, `<`, `>`, `\"`, `'`) and gives it back as a string: what a page interpolates. Not context-aware, so a `javascript:` URL survives it.",
      raw: "`raw(value)` gives a value back as a string with no escaping. This is the XSS door: every use is a deliberate act, and a review greps for `raw(` by name.",
      render: "`render(name, locals: {...}, layout: :app)` answers with view `name`: a `.html` file beside the DSL file, read at compile time and compiled into the emitted Rust, so the crate carries no template. The locals are exactly the names the view's, its layout's and its `{{ partial }}` calls' markers read (`set :layout` gives every render a layout, `layout: nil` opts out); a `{{ partial :name, key: value }}` in a view inlines `views/name.html`, whose own markers read only the call's arguments; a layout's `{{ yield :nav }}` writes the region the view fills with `{% content_for :nav %}…{% endcontent_for %}`. See [the views](views.md).",
      cookie: "`cookie(:name)` is the value of a signed cookie, or nil when it is absent, malformed or not signed by this key (`cookies secret: :setting` first); `cookie(:name, signed: false)` is a plain cookie, and `format:` picks `:hmac` or `:rails` for a signed one. In a route, a `before` filter or a `current` body. `set_cookie :name, value, http_only: true, same_site: :lax, secure: false, permanent: false, max_age: nil, signed: true, format: nil` and `delete_cookie :name` are statements of a route body; `permanent: true` is twenty years, and `signed: false` writes no MAC.",
      random_token: "`random_token` is 24 base58 characters (Rails' has_secure_token alphabet) from a cryptographically secure generator; `request_ip` is the client address, `request_base_url` the scheme and host the request was addressed to (Rails' request.base_url, no trailing slash; the Host header and http, unless `use_layer :trace, forwarded: true` trusts X-Forwarded-Host and X-Forwarded-Proto), `user_agent` the User-Agent header (empty when absent) and `turbo_frame_request?` whether the request carries a non-blank Turbo-Frame header (turbo-rails' turbo_frame_request?, a boolean), all for route, `before` and `current` bodies. `request_ip` reads the first `X-Forwarded-For` entry when `set :trust_forwarded_for, true` (or `use_layer :trace, forwarded: true`) says a proxy is trusted.",
      urlsafe_decode64: "`urlsafe_decode64(text)` is Ruby's `Base64.urlsafe_decode64(text)` as UTF-8 text, or nil where Ruby raises ArgumentError (malformed Base64: a length that is not a multiple of four after padding, a character outside the alphabet, padding before the end, set unused bits) or the bytes are not UTF-8; `/qr_code/:id` decodes its id with it.",
      url_encode: "`url_encode(text)` is Ruby's `URI.encode_www_form_component` (Rack::Utils.escape): the escaping Rails writes when it appends a query parameter, keeping `A-Za-z0-9-._*` (Ruby's form-encoding set, not RFC 3986's: `~` becomes `%7E`), writing a space as `+` and every other UTF-8 byte as `%XX`. Campfire's sign-in URL is `/session/new?email_address=` followed by `url_encode(email_address)`.",
      qr_code_svg: "`qr_code_svg(text)` is `RQRCode::QRCode.new(text).as_svg(viewbox: true, fill: :white, color: :black)` byte for byte (rqrcode_core 2.1.0's encoder: error correction level H, one segment, the first version with strictly more capacity than the bits, the mask with the fewest lost points), or nil where the text does not fit version 40.",
      active_storage_disk_path: "`active_storage_disk_path(key, filename, content_type, secret: :secret_key)` is `blob.url` on Active Storage's disk service: `/rails/active_storage/disk/<signed key>/<filename>`, where the signed key is ActiveStorage.verifier's message over `{key, disposition (inline, with the filename), content_type, service_name: \"local\"}` for purpose `blob_key`, expiring in five minutes. The path is relative: put `request_base_url` in front for the absolute URL Rails writes.",
      active_storage_verified_id: "`active_storage_verified_id(token, secret: :secret_key)` is the integer inside a blob's `signed_id` (ActiveStorage.verifier, purpose `blob_id`), or nil for a bad signature or purpose.",
      active_storage_verified_key: "`active_storage_verified_key(token, secret: :secret_key)` is the blob key inside a disk URL's signed key (purpose `blob_key`), or nil for a bad signature, wrong purpose or an expired URL.",
      inline_disposition: "`inline_disposition(filename)` is the `Content-Disposition` value Active Storage's disk service serves a blob with: `inline; filename=\"moon.jpg\"; filename*=UTF-8''moon.jpg` (ActionDispatch::Http::ContentDisposition: an ASCII `filename=` with other characters `?` or percent-encoded, the full name percent-encoded in `filename*=`).",
      plain_text: "`plain_text(html)` is Action Text's `to_plain_text` of a stored body (ActionText::PlainTextConversion with the trailing newlines removed: a paragraph ends in a blank line, a `div` or `br` in a newline), the conversion `attachments:` already uses. Written, with the `scraper` crate, only when a body calls it.",
      request_body: "`request_body` is the whole request body as UTF-8 text (Rails' `request.body.read.force_encoding(\"UTF-8\")`; bytes that are not UTF-8 become U+FFFD), for a route body. axum lets one extractor consume the body, so a route that reads `request_body` cannot also read params `in: :body` or `in: :form`; path and query params are fine.",
      request_path: "`request_path` is the URI path of the request (no query string), for a `before` filter, which has no `params`: the filter can tell which request it is running for.",
      request_method: "`request_method` is the request's HTTP method in upper case (\"GET\", \"POST\", ...), for a route and, like `request_path`, a `before` filter (Rails' `request.get?`/`request.head?`); `use_layer :method_override` has already rewritten it.",
      current: "`current(:user)` reads the per-request value a `current :user, returns: :User? do ... end` declares: computed on the first read and kept for the rest of the request, in routes, `before` filters and later currents. With `required: :authenticate` on the declaration, a route that does not skip that filter reads it at its non-nil type.",
      rails_signed_id: "`rails_signed_id(token, purpose: \"user/avatar\", secret: :secret_key, check_expiry: false)` is the integer id inside a Rails 8 `signed_id` token, or nil (bad MAC, wrong purpose, malformed, or an expiry present without `check_expiry: true`); `check_expiry: true` is Rails' `verified(token, purpose:)`: a token with no `exp` or a future one returns the id, one whose `exp` has passed is nil. `rails_signed_id_for(id, purpose:, secret:, expires_in: 14400)` writes that token (`expires_in:` is a positive integer literal of seconds and adds the `exp` Rails writes). `secret:` names a required string setting. A view writes tokens with markers: `{{ rails_signed_id id, purpose: \"user/avatar\", secret: :secret_key }}`, `{{ active_storage_blob_id blob_id, secret: :secret_key }}` (`blob.signed_id`) and `{{ active_storage_variation format, resize_to_limit: [1200, 800], secret: :secret_key }}` (a variation key; ActiveStorage.verifier is SHA1 over padded base64 with the key salt \"ActiveStorage\").",
      broadcast: "`broadcast \"user_\#{id}_reads\", \"room_id\" => room_id` is `ActionCable.server.broadcast name, { room_id: ... }`: every subscription listening on that name gets the JSON object as its message. Keys keep the order written, values are strings, numbers and bools, and `json_object(\"id\" => 1)` nests. It never waits for a socket. Needs a `cable`.",
      broadcast_to: "`broadcast_to \"action\" => \"start\", \"user\" => json_object(\"id\" => user.id, \"name\" => user.name)` in a channel's callback is `broadcast_to @room, ...`: the object goes to the name the channel's own `stream_for` made, so it needs a `stream_for` in the same channel.",
      broadcast_turbo: "`broadcast_turbo(global_id_param(\"Rooms::Open\", room_id, app: \"campfire\"), :messages, action: :append, target: \"messages\", html: render_string(:message, locals: {...}), maintain_scroll: true)` is turbo-rails' `broadcast_append_to`: the positional parts are the stream's name, joined with `:`, and the subscribers get the `<turbo-stream>` tag as a JSON string. `action:` is :append, :prepend, :replace, :update, :before, :after or :remove; every action but :remove takes `html:`. Needs a `cable`.",
      close_remote_connections: "`close_remote_connections(user.id, reconnect: true)` is Rails' `User#close_remote_connections` (`ActionCable.server.remote_connections.where(current_user: user).disconnect(reconnect:)`): every open Action Cable connection whose signed-in user has that id is sent `{\"type\":\"disconnect\",\"reason\":\"remote\",\"reconnect\":true}` and closed, running the channels' `on_unsubscribe` as a closed socket does. `reconnect:` is a literal true (the default) or false; the argument is the user's id (an :i64) for a record or :i64 current, or the string for a string current. The route never waits for a socket. Needs a `cable`.",
      render_string: "`render_string(:message, locals: {...})` renders a view to a string with no layout and does not answer with it (Rails' `render_to_string`/`ApplicationController.render(partial:)`): the markup a Turbo broadcast carries. The view is compiled into the crate and follows `render`'s rule for locals. Allowed in a route, a filter and a channel callback.",
      Bcrypt: "`Bcrypt.verify(plain, digest)` is a bool (false for a malformed digest) and `Bcrypt.hash(plain)` a string at cost 12; both run on a blocking thread, and nothing else is on `Bcrypt`."
    }.freeze

    module_function

    def call(name) = CALLS[name.to_sym]

    # Route verbs share their keyword docs under `:route`.
    def keyword(call, keyword)
      c = call.to_sym
      c = :route if ROUTE_VERBS.include?(c)
      KEYWORDS[[c, keyword.to_sym]]
    end

    def choices(call, keyword) = CHOICES[[call.to_sym, keyword.to_sym]]
  end
end
