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
      set: "Sinatra's `set :name, value`: `:port` and `:bind` configure the listener, `:listener` names a Rust type from a rust_file that is bound in place of the TCP listener (the hook for TLS), `:log` is `:text` or `:json` and installs the log subscriber, `:name` and `:version` are the crate's own metadata, `:public_folder` mounts a directory at \"/\", `:views`/`:layout` say where a body's `render` reads its views and which layout wraps them (see docs/views.md), and `set :rust, :none` refuses every declaration that injects Rust (see docs/sessions.md).",
      static: "Mounts a directory of files at a path prefix; tower-http ServeDir answers the requests, and the directory is copied into the generated crate. With `digest: true` each file is copied under `<stem>-<sha256 prefix><ext>` (only that name is served), and a view writes its URL with `{{ asset_path \"campfire.css\" }}`.",
      serve_file: "Answers one route with one file; the file is copied into the generated crate like a static mount.",
      openapi: "Has the service answer GET at this path with an OpenAPI 3.1 document of its routes, written by the compiler from the routes, the params and their descriptions and constraints; nothing is generated at run time (see docs/openapi.md).",
      params: "A group of fields a route accepts, turned into a struct; a route names it with `params:` and reads it in the body with `params[:field]`.",
      field: "One field of a params group: a snake_case name and a type symbol such as :string or :i32, or `map(...)`/`list(...)`. An `in: :form` field may take `name: \"message[body]\"`, a Rails wire key that leaves the DSL name (and params[:body], check() and errors) unchanged.",
      use_layer: "Names a tower-http middleware the whole router is wrapped in (:compression, :cors, :timeout or :trace, which also installs a log subscriber, see `set :log`), or the compiler's own :fetch_metadata, which answers 403 to a cross-site write (see docs/sessions.md), :csrf, which checks a signed token on every write and answers 403 (it needs `cookies secret:`, see docs/sessions.md), and :rate_limit, the compiler's fixed-window limiter (`per:` seconds, `burst:` requests, optional `path:`, 429 past the burst, per request_ip), and :private_cache, which appends `Cache-Control: private, no-cache` and `Vary: Cookie` to every response so a shared cache does not store an authenticated page (its `except:` lists static mount prefixes that leave the layer off; only public files may be named). A layer answers every route, so where it is written does not matter.",
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
      current: "A per-request value, `current :user, returns: :User? do ... end`: computed on its first read in a request and kept for the rest of it; routes and filters read it with current(:user) (see docs/sessions.md). `required: :authenticate` names the `before` filter that establishes it, so a route that does not skip that filter reads it non-nil.",
      database: "The one database the service's queries run against: `database :sqlite, path: \"notes.sqlite3\", env: \"DATABASE_PATH\"`. :sqlite is the only adapter; the server opens it, applies the migrations and checks every query once as it starts (see docs/database.md).",
      migrations: "A folder of numbered *.sql files, relative to the DSL file, that the server applies once each, in file-name order, as it starts; they are embedded in the binary (see docs/database.md).",
      record: "The row a query returns: a CamelCase name and `field` lines with a scalar type (:string, :i64, :f64, :bool), `optional: true` for a column that may be NULL. A body reads it like a params object and `json(...)` writes it.",
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
      %i[static digest] => "With true, copy and serve every file under a fingerprinted name (`campfire-<sha256 prefix>.css`) instead of its own, so a far-future Cache-Control is safe; a view writes the URL with `{{ asset_path \"campfire.css\" }}`.",
      %i[serve_file from] => "The file to serve, relative to the DSL file; it is copied into the generated crate the same way.",
      %i[rust_crate features] => "The crate features to turn on, a non-empty list of strings such as [\"ring\"]; naming either keyword writes the dependency as a table in Cargo.toml.",
      %i[rust_crate default_features] => "With false, writes default-features = false, so only the crate's `features:` are on; true (the default) leaves the crate's own defaults.",
      %i[openapi title] => "The document's title; the server's name when left out.",
      %i[openapi version] => "The document's API version, any non-empty string; the server's version when left out.",
      %i[use_layer origins] => "The origins :cors allows, each a string such as \"https://example.com\"; without origins: the layer is permissive.",
      %i[use_layer secs] => "How long :timeout lets a request take, as a positive whole number of seconds.",
      %i[use_layer forwarded] => "With true, :trace logs the visitor's address from the first entry of X-Forwarded-For (else the peer's) and installs a log subscriber; trust it only behind a proxy that sets the header.",
      %i[use_layer except] => "Public static path prefixes that leave :private_cache off, each an exact `static` mount prefix or a path inside one (a segment boundary); only files a static mount serves may be named, and a route or a page with a session or CSRF token cannot be exempted. Without it the layer stays on every response.",
      %i[route description] => "What the route does; with an `openapi` declaration it becomes the operation's summary and description in the served document, and the service serves no API document without one.",
      %i[route skip] => "The named `before` filters this route does not run, such as `[:authenticate]`; the filter still layers the router, and it compares the request's method and path with the skipping routes. Skipping a name no `before` declares is refused.",

      %i[field in] => "Which part of the request the field is read from: :path, :query, :body or :form (an HTML form body, read by axum's Form extractor). The verb decides the default (body for post/put/patch, query otherwise); :form is always written out, and a route's fields may come from more than one part only if each says which.",
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
      render: "`render(name, locals: {...}, layout: :app)` answers with view `name`: a `.html` file beside the DSL file, read at compile time and compiled into the emitted Rust, so the crate carries no template. The locals are exactly the names the view's, its layout's and its `{{ partial }}` calls' markers read (`set :layout` gives every render a layout, `layout: nil` opts out); a `{{ partial :name, key: value }}` in a view inlines `views/name.html`, whose own markers read only the call's arguments. See [the views](views.md).",
      cookie: "`cookie(:name)` is the value of a signed cookie, or nil when it is absent, malformed or not signed by this key (`cookies secret: :setting` first); `cookie(:name, signed: false)` is a plain cookie, and `format:` picks `:hmac` or `:rails` for a signed one. In a route, a `before` filter or a `current` body. `set_cookie :name, value, http_only: true, same_site: :lax, secure: false, permanent: false, max_age: nil, signed: true, format: nil` and `delete_cookie :name` are statements of a route body; `permanent: true` is twenty years, and `signed: false` writes no MAC.",
      random_token: "`random_token` is 24 base58 characters (Rails' has_secure_token alphabet) from a cryptographically secure generator; `request_ip` is the client address and `user_agent` the User-Agent header (empty when absent), both for route, `before` and `current` bodies.",
      current: "`current(:user)` reads the per-request value a `current :user, returns: :User? do ... end` declares: computed on the first read and kept for the rest of the request, in routes, `before` filters and later currents. With `required: :authenticate` on the declaration, a route that does not skip that filter reads it at its non-nil type.",
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
