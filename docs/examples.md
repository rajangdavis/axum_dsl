# Examples

The example services that ship with the repository.

_See also: [README](../README.md)._

| File | Shows |
|------|-------|
| `add.axum.rb` | a minimal service: a query-parameter route (`text(...)`), a path-parameter route and `json(...)`, and a `/slow` route (a `cmd_fn` running `sleep 2`) that `test/e2e_add.sh` uses to show SIGTERM draining an in-flight request |
| `controllers.axum.rb` | a [controller](controllers.md): a `before` filter with `except:`, a def returning a value, a top-level def, and laws over its routes |
| `laws.axum.rb` | [laws](laws.md) over params groups and helpers: commutativity, a bound, idempotence, a law-only helper chain and an example law; `test/test_laws.rb` runs them and checks a planted off-by-one is caught |
| `validate.axum.rb` | the generated `check()`: every field carries a constraint, so a violating request is a 400 — before the body runs, unless the route reads `errors[:field]` and renders the message itself (one form route keeps the 400, the other answers a status of its own); it also carries the `in: :form` routes and five `use_layer` middleware (compression, cors, timeout, trace, private_cache), and an `openapi "/openapi.json"` document of its routes and constraints (see [OpenAPI](openapi.md)) |
| `proxy.axum.rb` | `use_layer :trace, forwarded: true`: the request log names the first `X-Forwarded-For` entry instead of the peer, and the crate gains `tracing` and `tracing-subscriber` (see [Deploying the emitted crate](cli.md#deploying-the-emitted-crate)) |
| `assets.axum.rb` | serving files: a plain `static` mount, a `static ... digest: true` mount whose fingerprinted URL a view writes with `{{ asset_path }}`, a `serve_file` route, and a route that sets its own response headers; `use_layer :private_cache, except: ["/assets"]` keeps the private-cache layer on every response except the public fingerprint mount (`test/e2e_assets.sh` asserts both halves) |
| `csrf.axum.rb` | CSRF (see [Sessions](sessions.md)): `use_layer :fetch_metadata` outside `use_layer :csrf`, a form whose `{{ csrf_token }}` fills `authenticity_token`, the signed `_axum_dsl_csrf` cookie, and a POST that is 403 without a matching token; `make e2e-csrf` |
| `views.axum.rb` | pages the server renders: `render` with `locals:`, a `{{ partial }}` the signup form calls once per field, a `set :layout` layout with `{{ title }}` and `{{ yield }}`, a `{% raw %}` block a client framework owns, one `\|raw` use, `layout: nil` and a second layout (see [Views](views.md)) |
| `case.axum.rb` | a binding: `use_bindings :heck` loads `bindings/heck.rb`, three routes call `Heck.snake_case`, `kebab_case` and `upper_camel_case`, and the binding's `crate "heck", "0.5"` reaches the emitted `Cargo.toml` (see [Bindings](bindings.md)) |
| `split.axum.rb` | a service split across files: `use_dsl` of `split/params.axum.rb` and `split/routes.axum.rb`, which itself includes `split/status.axum.rb`; the fragments sit in a sub-folder so `examples/*.axum.rb` never builds one |
| `hatches.axum.rb` | every escape hatch: `rust_crate`, `rust_item`, `rust_fn`, `rust_file` (`rust/shout.rs`), `cmd_fn` (argv and stdin), `script_fn` (`sh` and `ruby`) and `file` read with `file_text`, each reached by a route (see [Bindings](bindings.md)) |
| `notes.axum.rb` | SQLite state (see [Database](database.md)): `database`, a `record`, three `query` declarations and an `execute`, and a migrations folder (`notes/db/migrate/`); four routes add, list, fetch (or 404) and delete notes, and `test/e2e_notes.sh` restarts the server on the same file and starts a second service whose query misses a record field |
| `upload.axum.rb` | uploads (see [The DSL](dsl.md)): `:upload` fields read from a multipart form (`curl -F`), an empty file input as nil, `_method=patch` inside a multipart body, `avatar.store(setting(:storage))` writing the Disk service path under a fresh key with `active_storage_blobs`/`active_storage_attachments` rows behind it, and a repeated `user_ids[]` form key read as `list(:i64)`; `make e2e-upload` |
| `cable.axum.rb` | Action Cable broadcasts (see [Cable](cable.md)): `stream_from`, `stream_for`, `after_subscribe`, `on_unsubscribe` and `perform` in a `channel` block, a signed Turbo stream, and routes that `broadcast` a JSON object and `broadcast_turbo` an appended and a removed `render_string` view; `test/cable_broadcast_check.mjs` opens two WebSocket clients and checks every frame byte for byte, driven by `make e2e-cable` (it needs node) |
| `login.axum.rb` | sessions with no app Rust (see [Sessions](sessions.md)): `cookies`, a `current :user`, `Bcrypt`, `random_token`, `set_cookie` / `delete_cookie`, `use_layer :fetch_metadata` and `set :rust, :none`; signup, login, `/me` and a `DELETE /session` logout over a `users` and a `sessions` table (`login/db/migrate/`), driven by `make e2e-login` |
| `login_rails.axum.rb` | Rails' signed cookie format (see [Sessions](sessions.md)): `cookies secret: :secret_key, format: :rails`, so a value is `Base64.strict_encode64(Marshal.dump(value))--HMAC-SHA1-hex`; `/set` writes one and `/me` reads it, `format: :rails7` on `/set7`/`/me7` writes and reads the JSON `_rails` value a default Rails 7/8 app uses, while `/unsigned` and `/plain` round-trip a plain cookie; `test/e2e_login_rails.sh` computes the Rails values in Ruby and checks both directions and forms |
| `locales.axum.rb` | Rails-style locales, opt-in (see [Views](views.md#locales)): `config/locales/en.yml` and `es.yml` read when the compiler runs, a view's lazy `{{ t ".title" }}` and an interpolated `{{ t ".welcome", name: user_name }}`, a route body's `t("health.ok")`, `?locale=es` choosing the locale, and one key only `en` holds that `es` answers in English; `set :locales` and `default_locale`; `make e2e-locales` (port 8088) |
| `tls.axum.rb` | `set :listener, "tls::TlsListener"`: a Rust type from a `rust_file` (`rust/tls_listener.rs`, tokio-rustls, certificate and key from `TLS_CERT`/`TLS_KEY`) is bound in place of the TCP listener, so the service speaks HTTPS only; it also uses plain `use_layer :trace` to show the request log (see [Deploying the emitted crate](cli.md#deploying-the-emitted-crate)) |

`examples/public/` is the fixture `assets.axum.rb` serves (html, css, json and txt, so the content-type
guess is exercised); the compiler copies it into the emitted crate, and `test/e2e_assets.sh` starts that
crate with itself as the working directory (see [the DSL](dsl.md)).

`examples/views/` is the view example's own folder, named after the example (`set :views, "views"`
resolves beside the DSL file); a second example that renders keeps its `.html` in `examples/<its own
name>/`, so two examples never share one folder. `examples/csrf_views/` and `examples/asset_views/` follow that rule for `csrf.axum.rb` and `assets.axum.rb`; `examples/fingerprints/campfire.css` is the fixture `assets.axum.rb` mounts with `digest: true`.

`examples/locales/` holds the view and the locale files `locales.axum.rb` reads (`set :views, "locales/views"`, `set :locales, "locales/config/locales"`).

`examples/cable/views/` holds the one view `cable.axum.rb` renders to a string for a Turbo broadcast.

`examples/notes/` holds the SQL migration `notes.axum.rb` applies, and `examples/login/` the one `login.axum.rb` applies.

`examples/bindings/` (the `heck` binding), `examples/split/` (the `use_dsl` fragments), `examples/rust/` (the
`rust_file` source) and `examples/hatches/` (the text file `file` reads) are the fixtures of the last three
examples.

The set is small because the compiler is early. `rmcp_dsl`, which this was ported from, has an example
per feature; ours grows the same way, one example per construct as each is verified. `make dsl-check`
checks every `examples/*.axum.rb`, `make check-e2e` builds each one and talks HTTP to it (`e2e-add`,
`e2e-validate`, `e2e-assets`, `e2e-csrf`, `e2e-views`, `e2e-locales`, `e2e-proxy`, `e2e-case`, `e2e-split`, `e2e-hatches`, `e2e-notes`, `e2e-cable`, `e2e-login`, `e2e-login-rails`, `e2e-tls`), and the goldens in `test/golden/` pin the Rust each example emits.
