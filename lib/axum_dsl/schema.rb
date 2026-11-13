# frozen_string_literal: true

module AxumDsl
  # DSL type -> Rust type.
  TYPES = { i32: "i32", i64: "i64", f64: "f64", bool: "bool", string: "String" }.freeze

  # Field types beyond the scalars: lists of strings, integers or floats. A field may also name another
  # params struct (a CamelCase symbol) to nest an object.
  FIELD_LISTS = %i[string_list i64_list f64_list].freeze
  # A file chosen in a multipart form (docs/dsl.md, "Uploads"): `field :avatar, :upload, in: :form, name: "user[avatar]"`.
  FIELD_UPLOADS = %i[upload].freeze
  # JSON schema string formats a field can advertise (:date_time is "date-time"). They are advice to the
  # client, as the JSON Schema standard treats `format`, not something the server checks.
  FORMATS = %i[uri email date_time date uuid hostname ipv4 ipv6].freeze
  # The wire formats a signed cookie may use (`cookies format:`, and `format:` on a cookie call): :hmac is the
  # compiler's own, :rails is Rails' classic MessageVerifier value, and :rails7 is the JSON/metadata format a Rails 7/8 app writes. Cookies::FORMATS names the module for each.
  COOKIE_FORMATS = %i[hmac rails rails7].freeze
  # The middleware a top-level `use_layer` names. Each tower-http layer needs its own Cargo feature (see
  # Emit::LAYER_FEATURES); `:fetch_metadata`, `:rate_limit`, `:csrf`, `:private_cache` and `:method_override` are the
  # compiler's own middleware and need none (docs/sessions.md, docs/dsl.md).
  LAYERS = %i[compression cors timeout trace fetch_metadata rate_limit csrf private_cache rack_defaults front method_override format_extension].freeze

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
  # `set :rust, :none` refuses every declaration that injects Rust of the file's own (docs/sessions.md), and
  # `set :trust_forwarded_for, true` makes request_ip trust X-Forwarded-For without the trace layer (docs/sessions.md).
  SETTINGS = { port: :uint, bind: :str, name: :str, version: :str, public_folder: :str,
               views: :str, locales: :str, layout: :setting, turbo_frame_layout: :setting, listener: :str, log: :setting, rust: :setting,
               trust_forwarded_for: :bool, merge_query_params: :bool }.freeze

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
  # :query for get/delete/head/options; :form is always explicit). `skip:` names the named `before` filters
  # this route does not run, as a list of symbols (`skip: [:authenticate]`); the filter matches the route's
  # method and path at run time, and a name no `before` declares is refused (docs/sessions.md).
  ROUTE_DECL = {
    in: %i[top controller], names: [:path], pos: [:str],
    kw: { params: [:camel, false], description: [:str, false], skip: [:snakes, false], cache: [[:private], false], also: [:snakes, false],
          action: [:snake, false], controller: [:str, false] },
    block: :body, optional_block: true
  }.freeze

  # A model association (`has_many :messages, dependent: :destroy`): the keywords are Rails', and a name with none
  # of `table:`/`model:` is read from the association's name at the end of the read (Db::Models). `as:` names a polymorphic
  # child (`<as>_type` and `<as>_id` columns); `through:` names another association of the same model.
  ASSOCIATION = {
    in: :model, names: [:name], pos: [:snake],
    kw: { through: [:snake, false], dependent: [%i[destroy delete_all], false], table: [:snake, false], model: [:model_name, false],
          foreign_key: [:column, false], as: [:snake, false] },
    block: nil
  }.freeze

  # `has_one :body_text, -> { where(name: "body") }, table: ..., as: :record`: a has_one takes Rails' optional scope lambda,
  # which may only hold `where(column: literal, ...)` on the target table (the reader checks it).
  HAS_ONE = ASSOCIATION.merge(names: %i[name body], pos: %i[snake lambda], optional_pos: 1).freeze

  # The signature table: the single source of truth for what a DSL call accepts. It drives the reader's
  # validation, the generated Sorbet `rbi/dsl.rbi`, the language server's hover and completion, and the
  # generated agent skill.
  #   in:    name of the enclosing call (:top for the file level, where top-level routes and filters live)
  #   names: positional argument names, in order (used by bin/gen_rbi)
  #   pos:   positional argument kinds, in order
  #   optional_pos: how many trailing `pos` arguments may be left out (1 for `before :name`)
  #   kw:    keyword => [kind, required]
  #   block: nil (no block), :decls (only DSL calls inside) or :body (Ruby subset)
  # Kinds: :lit (a string, number or true/false literal), :default (a :lit, or a flat array of them),
  #        :fieldtype (a field type symbol), :bool (true or false), :num (integer or float literal),
  #        :uint (non-negative integer literal), :str (plain string literal), :snake / :camel (symbol
  #        literal naming a snake_case / CamelCase non-keyword identifier), :column (a snake_case symbol, a
  #        Rust keyword allowed: a table column's name), :htypes (a helper's argument
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
    # is copied under `<stem>-<8 hex digits><ext>`, the digits Propshaft computes (AxumDsl::Propshaft; `version:` is
    # its assets version, "1.0" by default), a CSS file's `url(...)` names are rewritten to those names, and only that
    # name is served without Accept-Ranges; `max_age:` adds `Cache-Control: max-age=N, public`. A view writes the URL
    # with `{{ asset_path "campfire.css" }}` (see docs/views.md). A named `before` filter covers a mount like a
    # route; `skip:` lists the filters the mount does not run, which keeps an asset directory public.
    static: { in: :top, names: [:prefix], pos: [:str], kw: { dir: [:str, true], digest: [:bool, false], version: [:str, false], max_age: [:uint, false], skip: [:snakes, false] }, block: nil },
    # serve_file "/report.txt", from: "public/report.txt" answers one route with one file (tower-http
    # ServeFile), copied into the emitted crate the same way. `skip:` lists the named `before` filters the route
    # does not run, as a route's does.
    serve_file: { in: :top, names: [:path], pos: [:str], kw: { from: [:str, true], max_age: [:uint, false], skip: [:snakes, false] }, block: nil },
    # cable "/cable", authenticate_with: :user do channel "HeartbeatChannel" ... end declares an Action Cable endpoint
    # (docs/cable.md): a WebSocket upgrade at the path that speaks the `actioncable-v1-json` protocol. The connection
    # is authenticated by the named `current` (nil answers `disconnect unauthorized`), and each `channel` is a
    # subscription the client may confirm: `signed_stream:` names the setting a Turbo signed stream name is verified
    # with, `room_param:` the identifier key holding a room id, and `member_of:` the query that says whether the user
    # may enter that room. A named `before` filter does not run for the path: the endpoint authenticates itself.
    cable: { in: :top, names: [:path], pos: [:str], kw: { authenticate_with: [:snake, true] }, block: :decls },
    # A channel's block is optional and holds its callbacks (docs/cable.md): `stream_from { ... }` and `stream_for { ... }` end
    # in the broadcasting name the subscription listens to, `after_subscribe` and `on_unsubscribe` run when it is joined
    # and left, and `perform :action { ... }` answers a client's `message` command of that action. Each takes the
    # values it names as block parameters (`|user, room_id|`).
    channel: { in: :cable, names: [:name], pos: [:str], kw: { signed_stream: [:snake, false], room_param: [:snake, false], member_of: [:snake, false], on_subscribe: [:snake, false] }, block: :decls, optional_block: true },
    stream_from: { in: :channel, names: [], pos: [], kw: {}, block: :body },
    stream_for: { in: :channel, names: [], pos: [], kw: {}, block: :body },
    after_subscribe: { in: :channel, names: [], pos: [], kw: {}, block: :body },
    on_unsubscribe: { in: :channel, names: [], pos: [], kw: {}, block: :body },
    perform: { in: :channel, names: [:action], pos: [:snake], kw: {}, block: :body },
    # openapi "/openapi.json" makes the compiler write an OpenAPI 3.1 document of the routes below and has the
    # service answer GET at that path with it (lib/axum_dsl/openapi.rb). `title:` and `version:` default to
    # the server's name and version.
    openapi: { in: :top, names: [:path], pos: [:str], kw: { title: [:str, false], version: [:str, false] }, block: nil },
    # A group of fields a route accepts. The reader turns one into a struct; each field is a `field` call.
    params: { in: %i[top controller], names: [:name], pos: [:camel], kw: {}, block: :decls },
    # `in:` is what replaces Sinatra's magic merging of path, query and form values into one `params` hash:
    # it says which part of the request a field is read from, and is optional (the reader defaults it from
    # the verb). `name:` is a form field's wire key (a Rails `message[body]`), a serde rename that leaves
    # the DSL name alone. Every other keyword is the JSON Schema constraint the field carries.
    field: [{
      in: [:params, :record], names: %i[field_name type], pos: %i[snake fieldtype],
      kw: { description: [:str, false], optional: [:bool, false], default: [:default, false],
            min: [:num, false], max: [:num, false], exclusive_min: [:num, false], exclusive_max: [:num, false],
            multiple_of: [:num, false], min_length: [:uint, false], max_length: [:uint, false],
            pattern: [:str, false], enum: [:strs, false], format: [FORMATS, false],
            min_items: [:uint, false], max_items: [:uint, false],
            in: [[:path, :query, :body, :form], false], name: [:str, false],
            from: [:snake, false] }, # a record's list field: the query that fills it (docs/database.md)
      block: nil
    }, {
      # A table column is named as the database names it, so `:type` and the other Rust keywords are fine (:column);
      # the only option is `optional: true`.
      in: :table, names: %i[column_name type], pos: %i[column fieldtype],
      kw: { optional: [:bool, false] }, block: nil
    }],
    # use_layer :compression (or :cors, :timeout, :trace) names a tower-http middleware the whole router
    # is wrapped in (`:fetch_metadata` is the compiler's own: it refuses a cross-site write, and `:csrf` is
    # its token check -- it needs `cookies secret:`, see docs/sessions.md). A layer answers every route, so where the declaration sits in the file does not
    # matter; the emitter fixes the order (Emit::LAYER_ORDER) so the emitted router is the same whatever
    # the order of the declarations. `:cors` takes `origins:` (a list of origins; without it the layer is
    # permissive), `:timeout` takes `secs:` (a positive whole number of seconds) and `:trace` takes
    # `forwarded:` (true names the visitor's X-Forwarded-For address in its log lines); `:rate_limit`
    # takes `per:`, `burst:` and an optional `path:` (the compiler's own limiter, see docs/dsl.md), and
    # `:private_cache` appends `Cache-Control: private, no-cache` and `Vary: Cookie`; its `except:` lists
    # path prefixes served by a `static` mount that leave the layer off (only public files may be named).
    # `:rack_defaults` is Rails' default response headers for rendered HTML, one keyword per part
    # (`security_headers:`, `version:`/`revision:` setting names, `etag:`, `vary_accept:`, `preload:`,
    # `refresh_cookies:`, `session_cookie:`, `except:`; see docs/dsl.md). `:front` is what Rack::Deflater and
    # Thruster do in front of a Rails app (gzip, `Vary: Accept-Encoding`, `X-Cache`, a response cache); `cache_mb:`
    # sizes the cache, 0 turns it off. `:method_override` is Rack::MethodOverride: a POST whose `_method` form field
    # (or X-HTTP-Method-Override header) names PATCH, DELETE, ... is routed as that method; it takes no keywords.
    use_layer: { in: :top, names: [:name], pos: [LAYERS],
                 kw: { origins: [:strs, false], secs: [:uint, false], forwarded: [:bool, false],
                       per: [:uint, false], burst: [:uint, false], path: [:str, false], enabled: [:snake, false], except: [:strs, false],
                       security_headers: [:bool, false], version: [:snake, false], revision: [:snake, false],
                       etag: [:bool, false], vary_accept: [:bool, false], preload: [:strs, false],
                       refresh_cookies: [:strs, false], session_cookie: [:str, false], cache_mb: [:uint, false] }, block: nil },
    # A RESTful resource: the seven actions, filtered by only:/except:, at "/<name>". Member routes capture :id, so
    # their `:id` is the primary key of the resource's model (the one with `table: :<name>`, or `model:`); the controller names
    # its actions as defs (RB2). `params:` and `description:` take one value for every action or a hash by action. No nesting yet.
    resources: { in: :top, names: [:name], pos: [:snake],
                 kw: { only: [:snakes, false], except: [:snakes, false], controller: [:str, false], params: [:camel_or_actions, false],
                       description: [:str_or_actions, false], cache: [[:private], false], model: [:model_name, false] },
                 block: :body, optional_block: true },
    # A path prefix for the routes in its block: `scope path: "rooms/opens" do ... end`. No module/controller scope yet.
    # In a `model` it is a named relation, `scope :directs, -> { where(type: "Rooms::Direct") }`, kept for the queries to come.
    scope: [
      { in: :top, names: [], pos: [], kw: { path: [:str, true] }, block: :body },
      # (the name is a :column: `where` is a Rust keyword, and a scope called that is refused for hiding the operation)
      { in: :model, names: %i[name body], pos: %i[column lambda], kw: {}, block: nil }
    ],
    get: ROUTE_DECL,
    post: ROUTE_DECL,
    put: ROUTE_DECL,
    patch: ROUTE_DECL,
    delete: ROUTE_DECL,
    options: ROUTE_DECL,
    head: ROUTE_DECL,
    # An HTTP request filter: it runs for every route, in the emitter's layer order, for what they all
    # share (a content type, a guard). `before :authenticate do ... end` names it, so a route can say
    # `skip: [:authenticate]`; the name is optional (`before do ... end` is the anonymous filter), and a
    # duplicate name is refused. `after` is refused: see the header.
    # Inside a `controller`, `before :name, only: [...]` (no block) names one of its defs, run first in each of its
    # routes, as Rails' before_action. It guards (answers or passes on); `provides: :room` names the value the
    # route (and later filters) read from it, as Rails' `before_action :set_room` sets `@room`.
    before: { in: %i[top controller], names: [:name], pos: [:snake], optional_pos: 1,
              kw: { only: [:snakes, false], except: [:snakes, false], provides: [:snake, false] },
              block: :body, optional_block: true },
    # A controller groups routes the way a Rails controller does: its `before :name` filters and its `def`s (private
    # methods, expanded inline where they are called) are its own. `action:` names a route for `only:`/`except:`.
    # The name may be left out when the file is under controllers/: `controllers/accounts/bots.axum.rb` is
    # "Accounts::Bots", as Rails names a controller after its file. It holds routes, filters, params, defs, helpers
    # and laws, never SQL: a `record`, `query` or `execute` belongs in a `model`.
    controller: { in: :top, names: [:name], pos: [:str], optional_pos: 1, kw: {}, block: :decls },
    # A model groups the records, the SQL and the model methods (`def`s, shared by every route) of one Rails model:
    # `models/room.axum.rb` holds `model do ... end`, named "Room" after its file. It never answers a request: a route,
    # a filter or a controller belongs in a `controller` (docs/controllers.md, "Models"). It is named "Room" (`model :Room`
    # or `model "Room"`), `table:` names the declared table it owns, and its associations and scopes are the calls
    # below that are `in: :model` (docs/database.md, "Models").
    model: { in: :top, names: [:name], pos: [:model_name], optional_pos: 1, kw: { table: [:snake, false] }, block: :decls },
    # A concern holds the exprs several models share, `concern :Timestamps do expr ... end` (models/concerns/timestamps.axum.rb, named after
    # the Rails concern); a model brings them in with `include :Timestamps` (docs/database.md, "Models").
    concern: { in: :top, names: [:name], pos: [:camel], kw: {}, block: :decls },
    # `include :Timestamps` inside a `model`: the exprs of that concern are the model's (the model's table must have the columns they read).
    include: { in: :model, names: [:name], pos: [:camel], kw: {}, block: nil },
    has_many: ASSOCIATION,
    has_one: HAS_ONE,
    belongs_to: ASSOCIATION,
    # `has_one_attached :avatar`: Active Storage's one attached file; the compiler derives the associations `avatar_attachment` and
    # `avatar_blob`, the condition `attached(:avatar)` and the statements `attach(:avatar, ...)` runs (docs/database.md, "Attachments").
    has_one_attached: { in: :model, names: [:name], pos: [:snake], kw: {}, block: nil },
    # `private` in a controller, as in Rails: a marker for the reader of the file; every def is private already.
    private: { in: :controller, names: [], pos: [], kw: {}, block: nil },
    # What a request that matched no route answers with. `skip:` names the `before` filters such a request does not
    # run (Rails routes first, so an unknown path is a 404 before any controller filter: `skip: [:authenticate]`).
    not_found: { in: :top, names: [], pos: [], kw: { skip: [:snakes, false] }, block: :body },
    # What a body that raised answers with.
    error: { in: :top, names: [], pos: [], kw: {}, block: :body },
    # A typed function a body may call, the rmcp_dsl form carried over: its arguments and result are
    # declared, so a call is type-checked. A `def` (top level or in a `controller`) is the untyped kind: a method
    # expanded inline where it is called, which may read the request and answer it (docs/controllers.md).
    helper: {
      in: %i[top controller model], names: [:name], pos: [:snake],
      kw: { args: [:htypes, true], returns: [HELPER_TYPES.keys, true], kw: [:helper_kw, false], async: [:bool, false] },
      block: :body
    },
    # A property the compiler turns into a seeded proptest test under `cargo test` (lib/laws): `law :name,
    # forall: :Params, cases: 256 do |a, b| <bool> end` quantifies over the fields of a params group, within
    # their declared constraints; without `forall:` it is an example law, run once.
    law: { in: %i[top controller model], names: [:name], pos: [:snake], kw: { forall: [:camel, false], cases: [:uint, false] }, block: :body },
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
    # A named HTML allowlist for a view's `{{ body|sanitize :name }}` (docs/views.md): `sanitizer :message_body, tags: %w[p a ...],
    # attributes: %w[href class]` allows exactly those tags and those attributes (on any tag), `link_rel: false` keeps
    # ammonia from adding `rel="noopener noreferrer"` to links, and `autolink_target: "_blank"` links bare URLs and
    # e-mail addresses afterwards as Rails' auto_link does. `attachments: { "<content-type>" => :partial }` renders an
    # <action-text-attachment> of that type with the named view partial; `sounds:` and `sound_partials:` render a body
    # that is only `/play NAME` (docs/views.md, "Declared sanitizers").
    sanitizer: { in: :top, names: [:name], pos: [:snake],
                 kw: { tags: [:strs, true], attributes: [:strs, true], link_rel: [:bool, false], autolink_target: [:str, false],
                      attachments: [:hash, false], sounds: [:hash, false], sound_partials: [:hash, false] }, block: nil },
    # A per-request value, computed at most once on its first use: `current :user, returns: :User? do ... end`.
    # The block is a body that may call queries, cookie(:name), request_ip, helpers and the currents above it;
    # a route or a filter reads it with current(:user). `returns:` is what a query's `returns:` is.
    # `required: :authenticate` says the named `before` filter stops the request unless this nil-able value
    # is there, so a route that does not skip that filter reads it at its non-nil type (docs/sessions.md).
    # `reader: :current_user` also names it as a bare call, Rails' `current_user`: exactly current(:user), declared here.
    # `returns: :Record, missing: "message"` is a non-nil record: a body that yields nothing fails the request like `raise "message"`.
    current: { in: %i[top model], names: [:name], pos: [:snake], kw: { returns: [:creturns, true], required: [:filter_name, false], reader: [:snake, false], missing: [:str, false] },
               block: :body },
    # A named value a view may read without a `locals:` entry: `view_local :vapid_key do setting(:vapid_public_key) end`.
    # The block is a body, lowered in the context of each route that renders a view reading the name (docs/views.md,
    # "Locals without locals:"), so it may call current(:x), setting, queries and defs; it is computed only then.
    view_local: { in: %i[top controller], names: [:name], pos: [:snake], kw: {}, block: :body },
    # A block of named values a view may read without a `locals:` entry, declared once for a controller (or the top
    # level): `page_locals do account_css = account_custom_styles; signed_in = true end`. Each line is a `view_local`
    # with an expression instead of a block, scoped to the controller it is written in (a controller entry wins over
    # a top-level one of the same name); only the entries a render reads are computed (docs/views.md, "Locals
    # without locals:").
    page_locals: { in: %i[top controller], names: [], pos: [], kw: {}, block: :body },
    # A block of the names the layout reads, declared once for a controller (or the service): `layout_locals do
    # account_css = account_custom_styles; signed_in = true end`. A page local the layout reads is refused (it belongs
    # here); a layout local may also feed a page, which a frame page or a page that repeats the layout needs. A
    # controller entry wins over a top-level one; only entries a render reads are computed (docs/views.md, "Layout
    # locals").
    layout_locals: { in: %i[top controller], names: [], pos: [], kw: {}, block: :body },
    # Rails' flash, carried on a plain cookie as a suffix on its value (docs/sessions.md, "Flash"): `flash cookie:
    # "_campfire_session", notice: { notice_saved: "✓" }, alert: { room_not_found: "Room not found" }` declares every
    # message the service can show. `redirect(path, notice: :notice_saved)` writes `<token>.notice_saved`, and
    # `take_flash` in the page it lands on reads it once (a Flash: on, alert, key, text) and writes the bare token back.
    flash: { in: :top, names: [], pos: [], kw: { cookie: [:str, true], notice: [:hash, false], alert: [:hash, false] }, block: nil },
    # Locales are opt-in: `default_locale :en` names the locale a request without a `locale` query parameter (or with one
    # no file holds) is answered in. Without it the default is :en when a locale file holds it, else the only locale there is.
    default_locale: { in: :top, names: [:locale], pos: [:snake], kw: {}, block: nil },
    # SQL state (docs/database.md). `database :sqlite, path: "notes.sqlite3", env: "DATABASE_PATH"` names the one
    # database (the adapter is the first argument, only :sqlite is built; `env:` overrides `path:` at startup),
    # `migrations "db/migrate"` names the folder of *.sql files applied at startup, `record` declares the row a
    # query returns (its fields are `field` calls with a scalar type, `optional: true` for a NULL-able column),
    # and `query`/`execute` declare one statement each: the SQL is the user's text, run as written, with `:name`
    # placeholders that `args:` declares. A body calls one as `name(arg: value)`.
    database: { in: :top, names: [:adapter], pos: [:snake], kw: { path: [:str, true], env: [:str, false] }, block: nil },
    migrations: { in: :top, names: [:path], pos: [:str], kw: {}, block: nil },
    record: { in: %i[top model], names: [:name], pos: [:camel], kw: {}, block: :decls },
    # `table :rooms do field :id, :i64 ... end` declares a table of the database for the schema registry
    # (Db::Schema); it emits no Rust. It is written where a `record` is, because a model owns its table.
    table: { in: %i[top model], names: [:name], pos: [:snake], kw: {}, block: :decls },
    query: { in: %i[top model], names: [:name], pos: [:snake], kw: { args: [:sqlargs, true], returns: [:qreturns, true], sql: [:str, false] }, block: :body, optional_block: true },
    execute: { in: %i[top model], names: [:name], pos: [:snake], kw: { args: [:sqlargs, true], sql: [:str, false] }, block: :body, optional_block: true },
    # `expr :now, type: :string, sql: "strftime(...)"` names a SQL expression for the relations to come; with `of: :t` the
    # template writes the table it applies to as `{t}`. In a `model` or a `concern` the `of: :t` is implied by a `{t}`. It emits no Rust
    # (docs/database.md, "Models").
    expr: { in: %i[top model concern], names: [:name], pos: [:snake], kw: { type: [%i[string i64 f64 bool], true], sql: [:str, true], of: [:snake, false], args: [:sqlargs, false] }, block: nil },
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
            kw: { as: [:snake, true], env: [:str, false], entries: [:snakes, false], unchecked: [:file_checks, false], binary: [:bool, false] }, block: nil },
    # Subprocess escape hatches (any language). Arguments are separate argv entries or stdin,
    # never shell text. Called from bodies as rust(:name, ...) like any rust_fn.
    cmd_fn: { in: :top, names: [:name], pos: [:snake],
              kw: { program: [:str, true], argv: [:strs, false], args: [:types, true],
                    returns: [[:string], true], pass: [%i[argv stdin], false], async: [:bool, false] }, block: nil },
    script_fn: { in: :top, names: [:name], pos: [:snake],
                 kw: { interpreter: [:str, true], code: [:str, true], args: [:types, true],
                       returns: [[:string], true], flag: [:str, false], async: [:bool, false] }, block: nil }
  }.freeze

  # A name may carry one signature per context: its SIG entry is then an Array of signature hashes whose `in:`
  # sets do not overlap (`scope` is a route at the top level and a named filter in a `model`). An entry that is
  # one hash is the common case and reads as before. Every lookup goes through these; `table` is SIG unless a
  # test hands in its own.
  #
  # Every signature of `name` ([] when it is not a DSL call).
  def self.sig_variants(name, table = SIG)
    entry = table[name]
    entry.nil? ? [] : (entry.is_a?(Array) ? entry : [entry])
  end

  # The signature `name` has in `ctx`, or nil when the call is not allowed there.
  def self.sig(name, ctx, table = SIG) = sig_variants(name, table).find { |s| Array(s[:in]).include?(ctx) }

  # The call names allowed directly inside `ctx`, in table order.
  def self.sig_names(ctx, table = SIG) = table.keys.select { |name| sig(name, ctx, table) }

  # Yields (name, signature) for every signature of the table, a name with several once per signature.
  def self.each_sig(table = SIG)
    return enum_for(:each_sig, table) unless block_given?

    table.each_key { |name| sig_variants(name, table).each { |s| yield name, s } }
  end

  # Refuses a name whose signatures share a context: which one a call meant would be a guess.
  def self.check_sigs!(table = SIG)
    table.each_key do |name|
      seen = []
      sig_variants(name, table).each do |s|
        clash = Array(s[:in]) & seen
        raise ArgumentError, "SIG: `#{name}` has two signatures for #{clash.map(&:inspect).join(", ")}" unless clash.empty?

        seen.concat(Array(s[:in]))
      end
    end
  end

  check_sigs!
end
