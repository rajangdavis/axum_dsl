# frozen_string_literal: true

module AxumDsl
  # DSL type -> Rust type.
  TYPES = { i32: "i32", i64: "i64", f64: "f64", bool: "bool", string: "String" }.freeze

  # Field types beyond the scalars: lists of strings, integers or floats. A field may also name another
  # params struct (a CamelCase symbol) to nest an object.
  FIELD_LISTS = %i[string_list i64_list f64_list].freeze
  # JSON schema string formats a field can advertise (:date_time is "date-time"). They are advice to the
  # client, as the JSON Schema standard treats `format`, not something the server checks.
  FORMATS = %i[uri email date_time date uuid hostname ipv4 ipv6].freeze
  # The wire formats a signed cookie may use (`cookies format:`, and `format:` on a cookie call): :hmac is the
  # compiler's own, :rails is Rails' MessageVerifier value. Cookies::FORMATS names the module for each.
  COOKIE_FORMATS = %i[hmac rails].freeze
  # The middleware a top-level `use_layer` names. Each is a tower-http layer the emitter puts on the
  # router, and each needs its own Cargo feature (see Emit::LAYER_FEATURES); `:fetch_metadata` is the
  # compiler's own middleware and needs none (docs/sessions.md).
  LAYERS = %i[compression cors timeout trace fetch_metadata rate_limit csrf].freeze

  # Types a helper declares for its arguments and result. Lists are spelled out, and a trailing ? means
  # nil-able: string? is "a string or nil".
  HELPER_TYPES = { string: :string, i32: :i32, i64: :i64, f64: :f64, bool: :bool,
                   string_list: :strs, i64_list: :i64s, f64_list: :f64s,
                   string?: :ostr, i32?: :oi32, i64?: :oi64, f64?: :of64, bool?: :obool,
                   string_list?: :ostrs, i64_list?: :oi64s, f64_list?: :of64s }.freeze

  # The checks a `file` declaration may turn off with `unchecked:`; the path and entry checks always run.
  FILE_CHECKS = %i[each_read args].freeze

  # What `set :name, value` accepts, and the kind of value each setting takes. `set` is Sinatra's way of
  # configuring a service without a `configure` block: `set :port, 4567` is where an axum service learns
  # what to bind, `set :public_folder, "public"` mounts that directory at "/", as Sinatra does, and
  # `set :views, "views"`/`set :layout, :app` say where a body's `render` reads its views and which one
  # wraps them (see Views). A file may also name its crate and version with `set :name`/`set :version`, the
  # settings the `server` declaration carries. `set :listener, "tls::TlsListener"` names a Rust type from a
  # rust_file that the emitted main binds in place of tokio's TcpListener (the TLS hook), and
  # `set :log, :text` or `:json` picks the format of the log subscriber (see Emit#log_format), and
  # `set :rust, :none` refuses every declaration that injects Rust of the file's own (docs/sessions.md).
  SETTINGS = { port: :uint, bind: :str, name: :str, version: :str, public_folder: :str,
               views: :str, layout: :setting, listener: :str, log: :setting, rust: :setting }.freeze

  SNAKE  = /\A[a-z][a-z0-9_]*\z/
  CAMEL  = /\A[A-Z][A-Za-z0-9]*\z/
  SEMVER = /\A\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?\z/
  RUST_KW = %w[
    as async await break const continue crate dyn else enum extern false fn for if impl in let
    loop match mod move mut pub ref return self Self static struct super trait true type unsafe
    use where while abstract become box do final macro override priv try typeof unsized virtual yield
  ].freeze

  # A route verb's declaration: Sinatra puts `get "/x" do ... end` at the top level of a file, so the route
  # calls are file-level too. `path` uses Sinatra's `:name` capture syntax, translated to axum 0.8's
  # `{name}`; a route REQUIRES its block, which is the body language. `params:` names a `params` block whose
  # fields the body reads as `params[:field]`, and `in:` on each field says whether it arrives in the path,
  # the query string, the body or a form (the reader defaults it from the verb: :body for post/put/patch,
  # :query for get/delete/head/options; :form is always explicit).
  ROUTE_DECL = {
    in: :top, names: [:path], pos: [:str],
    kw: { params: [:camel, false], description: [:str, false] },
    block: :body
  }.freeze

  # The signature table: the single source of truth for what a DSL call accepts. It drives the reader's
  # validation, the generated Sorbet `rbi/dsl.rbi`, the language server's hover and completion, and the
  # generated agent skill.
  #   in:    name of the enclosing call (:top for the file level, where top-level routes and filters live)
  #   names: positional argument names, in order (used by bin/gen_rbi)
  #   pos:   positional argument kinds, in order
  #   kw:    keyword => [kind, required]
  #   block: nil (no block), :decls (only DSL calls inside) or :body (Ruby subset)
  # Kinds: :lit (a string, number or true/false literal), :default (a :lit, or a flat array of them),
  #        :fieldtype (a field type symbol), :bool (true or false), :num (integer or float literal),
  #        :uint (non-negative integer literal), :str (plain string literal), :snake / :camel (symbol
  #        literal naming a snake_case / CamelCase non-keyword identifier), :htypes (a helper's argument
  #        types), :helper_kw (a helper's keyword parameters), :types (a Rust fn's argument types), :strs
  #        (a list of string literals), :snakes (a list of snake_case symbols), :file_checks (FILE_CHECKS),
  #        :setting (a :lit, or a symbol naming what the setting points at, as `set :layout, :app` does),
  #        :sqlargs (a hash literal of a query's arguments, `{ limit: :i64 }`, each a scalar type) and :qreturns
  #        (what a query returns: `list(:Record)`, `:Record?` or a scalar type, `?` for nil-able),
  #        or an Array of allowed symbol literals.
  #
  # Refused, and so absent, each for a reason that is part of the contract:
  #   `after do ... end`   axum has no filter that runs after a handler has built its response; only
  #                        `before` has an equivalent there.
  #   `erb` / `haml`       Sinatra renders a Tilt template at run time, and a Tilt template's extension
  #                        picks its engine and its escaping. A view here is a `.html` file the compiler
  #                        reads before the crate exists (Views, docs/views.md), so the extension is the
  #                        escaping context and a template format of its own is not a view.
  #   `send_file`          a body-level send_file would have to await a file service, which no response
  #                        helper does; declare `serve_file "/report.txt", from: "..."` instead.
  #   `configure do ... end`
  #                        Sinatra's configure block sets per-environment Rack options; the DSL configures
  #                        with `set`, and a service has no environment concept.
  #   `development?` / `production?`
  #                        Nothing in a compiled service is conditional on the environment; a `setting`
  #                        reads one value from it at startup instead.
  #   a path with `?` or an inline regex
  #                        axum's router has no optional segments and no patterns beyond one named capture;
  #                        `:name` is the whole of the route path syntax, so a pattern that is not a
  #                        `:name` segment is refused rather than silently matched differently.
  SIG = {
    # The crate a file compiles to. Optional, and the only call that names it: `server` has no block
    # because the routes are top level (Sinatra's shape), so it carries metadata only.
    server: {
      in: :top, names: [:name], pos: [:str],
      kw: { version: [:str, true] },
      block: nil
    },
    # Sinatra's `set :name, value`. `port` and `bind` configure the listener; `name` and `version` are the
    # crate's own metadata.
    set: { in: :top, names: %i[name value], pos: [SETTINGS.keys, :setting], kw: {}, block: nil },
    # static "/assets", dir: "public" mounts a directory of files at a path prefix: a request under the
    # prefix is answered by tower-http ServeDir, which guesses the content type from the extension and
    # answers an empty 404 for a missing file and for a path holding `..` or a backslash. The directory is
    # copied into the emitted crate at the same relative path, so the running service finds it beside its
    # own Cargo.toml; `set :public_folder, "public"` is the same mount at "/". With `digest: true` every file
    # is copied under `<stem>-<sha256 prefix><ext>` and only that name is served, and a view writes the URL
    # with `{{ asset_path "campfire.css" }}` (see docs/views.md).
    static: { in: :top, names: [:prefix], pos: [:str], kw: { dir: [:str, true], digest: [:bool, false] }, block: nil },
    # serve_file "/report.txt", from: "public/report.txt" answers one route with one file (tower-http
    # ServeFile), copied into the emitted crate the same way.
    serve_file: { in: :top, names: [:path], pos: [:str], kw: { from: [:str, true] }, block: nil },
    # openapi "/openapi.json" makes the compiler write an OpenAPI 3.1 document of the routes below and has the
    # service answer GET at that path with it (lib/axum_dsl/openapi.rb). `title:` and `version:` default to
    # the server's name and version.
    openapi: { in: :top, names: [:path], pos: [:str], kw: { title: [:str, false], version: [:str, false] }, block: nil },
    # A group of fields a route accepts. The reader turns one into a struct; each field is a `field` call.
    params: { in: :top, names: [:name], pos: [:camel], kw: {}, block: :decls },
    # `in:` is what replaces Sinatra's magic merging of path, query and form values into one `params` hash:
    # it says which part of the request a field is read from, and is optional (the reader defaults it from
    # the verb). `name:` is a form field's wire key (a Rails `message[body]`), a serde rename that leaves
    # the DSL name alone. Every other keyword is the JSON Schema constraint the field carries.
    field: {
      in: [:params, :record], names: %i[field_name type], pos: %i[snake fieldtype],
      kw: { description: [:str, false], optional: [:bool, false], default: [:default, false],
            min: [:num, false], max: [:num, false], exclusive_min: [:num, false], exclusive_max: [:num, false],
            multiple_of: [:num, false], min_length: [:uint, false], max_length: [:uint, false],
            pattern: [:str, false], enum: [:strs, false], format: [FORMATS, false],
            min_items: [:uint, false], max_items: [:uint, false],
            in: [[:path, :query, :body, :form], false], name: [:str, false] },
      block: nil
    },
    # use_layer :compression (or :cors, :timeout, :trace) names a tower-http middleware the whole router
    # is wrapped in (`:fetch_metadata` is the compiler's own: it refuses a cross-site write, and `:csrf` is
    # its token check -- it needs `cookies secret:`, see docs/sessions.md). A layer answers every route, so where the declaration sits in the file does not
    # matter; the emitter fixes the order (Emit::LAYER_ORDER) so the emitted router is the same whatever
    # the order of the declarations. `:cors` takes `origins:` (a list of origins; without it the layer is
    # permissive), `:timeout` takes `secs:` (a positive whole number of seconds) and `:trace` takes
    # `forwarded:` (true names the visitor's X-Forwarded-For address in its log lines); `:rate_limit`
    # takes `per:`, `burst:` and an optional `path:` (the compiler's own limiter, see docs/dsl.md).
    use_layer: { in: :top, names: [:name], pos: [LAYERS],
                 kw: { origins: [:strs, false], secs: [:uint, false], forwarded: [:bool, false],
                       per: [:uint, false], burst: [:uint, false], path: [:str, false] }, block: nil },
    get: ROUTE_DECL,
    post: ROUTE_DECL,
    put: ROUTE_DECL,
    patch: ROUTE_DECL,
    delete: ROUTE_DECL,
    options: ROUTE_DECL,
    head: ROUTE_DECL,
    # An HTTP request filter: it runs before every route that follows it, for what they all share (a
    # content type, a guard). `after` is refused: see the header.
    before: { in: :top, names: [], pos: [], kw: {}, block: :body },
    # What a request that matched no route answers with.
    not_found: { in: :top, names: [], pos: [], kw: {}, block: :body },
    # What a body that raised answers with.
    error: { in: :top, names: [], pos: [], kw: {}, block: :body },
    # A typed function a body may call, the rmcp_dsl form carried over: its arguments and result are
    # declared, so a call is type-checked. Sinatra's `helpers do ... def ... end` is deliberately NOT
    # implemented yet: it needs a class-bodied analysis the typed form already gives, with more surface.
    helper: {
      in: :top, names: [:name], pos: [:snake],
      kw: { args: [:htypes, true], returns: [HELPER_TYPES.keys, true], kw: [:helper_kw, false], async: [:bool, false] },
      block: :body
    },
    # A value the service reads from its environment when it starts: setting(:name) in a body.
    setting: {
      in: :top, names: [:name], pos: [:snake],
      kw: { env: [:str, true], description: [:str, false], default: [:lit, false], optional: [:bool, false], secret: [:bool, false],
            type: [%i[string i64 f64 bool], false] },
      block: nil
    },
    # Cookies (docs/sessions.md). `cookies secret: :secret_key` names the setting every signed cookie is signed
    # with (a required string of at least 32 bytes when the server starts); `format:` is :hmac (the default) or
    # :rails, the wire format of the signed cookies. A body then reads one with cookie(:name), and a route writes
    # one with set_cookie / delete_cookie; a cookie call may override the format, and signed: false is a plain
    # cookie. One declaration per file.
    cookies: { in: :top, names: [], pos: [], kw: { secret: [:snake, true], format: [COOKIE_FORMATS, false] }, block: nil },
    # A per-request value, computed at most once on its first use: `current :user, returns: :User? do ... end`.
    # The block is a body that may call queries, cookie(:name), request_ip, helpers and the currents above it;
    # a route or a filter reads it with current(:user). `returns:` is what a query's `returns:` is.
    current: { in: :top, names: [:name], pos: [:snake], kw: { returns: [:qreturns, true] }, block: :body },
    # SQL state (docs/database.md). `database :sqlite, path: "notes.sqlite3", env: "DATABASE_PATH"` names the one
    # database (the adapter is the first argument, only :sqlite is built; `env:` overrides `path:` at startup),
    # `migrations "db/migrate"` names the folder of *.sql files applied at startup, `record` declares the row a
    # query returns (its fields are `field` calls with a scalar type, `optional: true` for a NULL-able column),
    # and `query`/`execute` declare one statement each: the SQL is the user's text, run as written, with `:name`
    # placeholders that `args:` declares. A body calls one as `name(arg: value)`.
    database: { in: :top, names: [:adapter], pos: [:snake], kw: { path: [:str, true], env: [:str, false] }, block: nil },
    migrations: { in: :top, names: [:path], pos: [:str], kw: {}, block: nil },
    record: { in: :top, names: [:name], pos: [:camel], kw: {}, block: :decls },
    query: { in: :top, names: [:name], pos: [:snake], kw: { args: [:sqlargs, true], returns: [:qreturns, true], sql: [:str, true] }, block: nil },
    execute: { in: :top, names: [:name], pos: [:snake], kw: { args: [:sqlargs, true], sql: [:str, true] }, block: nil },
    # Load a trusted binding (bindings/<name>.rb); bodies then call Module.method(...) as plain Ruby.
    use_bindings: { in: :top, names: [:name], pos: [:snake], kw: {}, block: nil },
    # use_dsl "dsl/x.axum.rb" splices in the declarations of a fragment file; a fragment is read at the file
    # level (the same calls a file makes), so it has no context of its own.
    use_dsl: { in: :top, names: [:path], pos: [:str], kw: {}, block: nil },
    fragment: { in: :top, names: [], pos: [], kw: {}, block: :decls },
    # Tier 2 (SKETCH.md): injected Rust. rust_fn declares the signature of a function that lives in a
    # rust_item block, so bodies can call it as rust(:name, args) and be type-checked. Its result takes the
    # helper types, so `returns: :string?` is an Option<String> the body must handle as nil-able.
    rust_crate: { in: :top, names: %i[crate version], pos: %i[str str],
                  kw: { features: [:strs, false], default_features: [:bool, false] }, block: nil },
    rust_item: { in: :top, names: [:code], pos: [:str], kw: {}, block: nil },
    rust_fn: { in: :top, names: [:name], pos: [:snake],
               kw: { args: [:types, true], returns: [HELPER_TYPES.keys, true], from: [:snake, false], async: [:bool, false] }, block: nil },
    # rust_file loads a hand-written .rs file that lives next to the DSL file as module src/<as>.rs;
    # `from:` on rust_fn says the function is in that module.
    rust_file: { in: :top, names: [:path], pos: [:str], kw: { as: [:snake, true], uses: [[:subprocess], false] }, block: nil },
    # file "python/x.py", as: :x loads any file beside the DSL file; the service reads it from disk on each
    # call. `entries:` names the Python functions it calls, checked against the file.
    file: { in: :top, names: [:path], pos: [:str],
            kw: { as: [:snake, true], env: [:str, false], entries: [:snakes, false], unchecked: [:file_checks, false] }, block: nil },
    # Subprocess escape hatches (any language). Arguments are separate argv entries or stdin,
    # never shell text. Called from bodies as rust(:name, ...) like any rust_fn.
    cmd_fn: { in: :top, names: [:name], pos: [:snake],
              kw: { program: [:str, true], argv: [:strs, false], args: [:types, true],
                    returns: [[:string], true], pass: [%i[argv stdin], false], async: [:bool, false] }, block: nil },
    script_fn: { in: :top, names: [:name], pos: [:snake],
                 kw: { interpreter: [:str, true], code: [:str, true], args: [:types, true],
                       returns: [[:string], true], flag: [:str, false], async: [:bool, false] }, block: nil }
  }.freeze
end
