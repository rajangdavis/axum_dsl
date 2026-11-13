# The command line

The `axum_dsl` command and its subcommands.

_See also: [README](../README.md)._

| Command | Does |
|---------|------|
| `axum_dsl check FILE [--format json]` | Parse, type-check, report notifications; write nothing. `--format json` prints one document for editors and agents: `{ok, file, inputs, notes, hidden}` or `{ok: false, file, error: {file, line, col, message, suggestions}}`. Exit 1 on failure. Compile errors name the valid choices and suggest the nearest name when one looks like a typo (``unsupported call `upcas` ...; did you mean `upcase`?``); `suggestions` carries those names. `--types` (with `--format json`) adds `types`: `[{line, col, end_line, end_col, kind, type, name?}]` for every parameter, local and expression the compiler typed (lines and columns are 1-based, `end_col` exclusive, types read like Sorbet: `String`, `Integer (i64)`, `T.nilable(String)`), which is what an editor needs to show types in a body. |
| `axum_dsl graph FILE [--why NODE \| --impact NODE] [--format json]` | How the types derive: a graph of what takes its type from what, with the rule that did it (`select`, `widen bool->i64`, `has_one_attached ...`). Nodes are `kind:qualified.name` ids: `column:rooms.id`, `expr:owned_by`, `field:RoomFlag.flag` (a record field), `attached:User.avatar`, `assoc:User.avatar_attachment`, `query:attach_user_avatar`, `param:ROUTE.name`. With no option it prints the edges `to <- from (rule)`. `--why NODE` prints one node's derivation, down to the nodes it comes from; `--impact NODE` lists every node that takes its type from NODE, directly or not (what a change to a column reaches). `--format json` prints `{nodes, edges}`, `{node, edges}` or `{node, impact}`. Nothing is built or written, and an unknown node is an error (exit 1). The language server shows the same chain on hover, jumps to the source on go-to-definition, and answers `textDocument/references` on a column or expr with the nodes derived from it. |
| `axum_dsl console FILE [-o DIR] [--db PATH]` | A typed, read-only console over the app's declared queries ([Console](console.md)): builds the crate only when it is older than its binary, starts the binary in its `--console` mode on the database (`--db`, else the app's `database` env variable or path) and reads lines such as `recent_notes(limit: 5)`. The compiler checks the query name and each argument's type before anything is sent; the answer is a table with the SQL and the declared row type. Refuses a database with migrations not yet applied. `.help` lists the meta commands. |
| `axum_dsl lsp` | Run a language server on stdio for DSL files: diagnostics from the compiler over the open buffer, plus hover and completion from the declaration table (see [Editor support](editor-support.md)). |
| `axum_dsl rbi FILE... [-o DIR]` | Write Sorbet signatures for the helpers the files declare (default `sorbet/rbi/axum_dsl/dsl_helpers.rbi`), so DSL files can be `# typed: true`. |
| `axum_dsl build FILE [-o DIR] [--release] [--emit-only]` | Write the crate (default `build/NAME`) and run `cargo build`. A rustc error inside generated code is printed at the DSL line that produced it. |
| `axum_dsl run FILE [-o DIR] [--release]` | Build, then run the service; it listens on the port `set :port, N` names (default 4567), unless `PORT` says otherwise (see [Deploying the emitted crate](#deploying-the-emitted-crate)). |
| `axum_dsl test FILE [-o DIR]` | Build the crate, then check every [law](laws.md) with `cargo test`. A failure names the law, its DSL line and the minimal failing input; `AXUM_DSL_SEED=<u64>` explores other inputs. |
| `axum_dsl schema-check FILE [-o DIR]` | Build the crate, then run the binary with `--schema-check`: the migrations and every `query`/`execute` on a fresh in-memory database, with no server, settings or database file. Prints `schema-check: ok, N statement(s) prepared` and exits 0, or prints the startup message (a query that "does not select the columns of its record: missing [...], not a field [...]", or SQLite's own) and exits 2. Refused for a file with no `database`. See [Database](database.md#checking-queries-at-build-time). |
| `axum_dsl dev FILE [-o DIR] [--release]` | Build and start the service, then watch every file the compiler read (the DSL file and its `use_bindings`, `rust_file`, `file`, view and asset inputs; the set is recomputed after each read) by polling modification times. On a change it re-reads, re-emits and rebuilds: a compile error or a failed build is printed and the old server keeps running; a good build sends the old server SIGTERM, waits for it to drain, and starts the new one, printing `axum_dsl dev: restarted (N ms build)`. The server is the built binary run directly (not `cargo run`), with the crate directory as its working directory; `PORT` and `BIND` pass through. Ctrl-C or SIGTERM to `dev` stops the server and exits 0. Browser live-reload is not part of it. |
| `axum_dsl emit-diff FILE (--against DIR \| --overlay JSON) [--summary] [--raw]` | Show what a change does to the generated crate, with no cargo and nothing written; see [Comparing generated crates](#comparing-generated-crates). Exit 0 identical, 1 different, 2 usage or compile error. |
| `axum_dsl init NAME [-o DIR] [--force] [--no-bindings]` | Scaffold a new project: write `DIR/NAME.axum.rb` (a minimal service that compiles) and a `DIR/bindings/` folder holding a `.gitkeep` so an empty folder survives version control. Refuses to overwrite an existing file without `--force`; `--no-bindings` skips the folder. Default `DIR` is `.`. |
| `axum_dsl skill [-o DIR]` | Write an agent skill folder (`axum-dsl/SKILL.md` plus references) that teaches the DSL. The reference pages are generated from the compiler, so they match the installed version. |
| `--print-inputs` | Print the paths the compiler read — the DSL file, every `use_bindings` file, each `rust_file`, each `file` and each migration — one per line, and exit. `check --format json` also carries them as `inputs`. |
| `--warn SPEC`, `--notice SPEC` | Choose which notifications are printed (`all`, `none`, or codes). |
| `--version` | Print the version, and the axum version the generated services are built against. |

The original form still works: `axum_dsl FILE -o DIR`, `--check`, `--dump-ir`.

`build`, `run`, `dev` and `--emit-only` write only the crate files whose bytes changed, so a rebuild with the same
dependencies leaves `Cargo.toml` (and its mtime) alone. A build also records what it emitted in `DIR/.axum_dsl-files`
and removes the files a previous build into the same `DIR` wrote and this one does not — an asset whose `static`
digest changed, a `static` or `serve_file` that was deleted — so nothing stale is left to be served; it never
removes a file it did not write.

## Comparing generated crates

`axum_dsl emit-diff FILE` compiles in memory and compares two crates; it runs no cargo and writes no file. Exactly one of:

- `--against DIR`: "before" is the crate an earlier `axum_dsl FILE -o DIR` wrote into DIR (that form writes the crate and stops before cargo); "after" is the tree on disk now. A missing DIR is an error that says so.
- `--overlay JSON` (a file, or `-` for stdin): "before" is the tree on disk; "after" is the same tree with the files named in the JSON object `{"controllers/rooms.axum.rb": "full new text"}` replaced (paths absolute or relative to FILE's folder). This is how an editor asks what an unsaved change would do to the generated code: the texts stand in for their files the way the language server's open buffers do.

The source map `axum_dsl.map.json` is not compared, and neither is a line that differs only in a DSL position (`models/bot.axum.rb:94`); those lines are counted in one line of output. The output is a summary, one line per changed unit as the source map names it (`changed: route `patch /account` (controllers/accounts.axum.rb:58)`, `added: ...`, `removed: ...`, or `changed: (unmapped) src/main.rs lines 10-12`), then a unified diff with two lines of context whose hunks are headed with the units they touch. A line longer than 160 characters is first split at statement boundaries outside string literals (after `; ` and ` { `, before ` }`), so a handler that is one line shows only the piece that changed; hunk line numbers count those pieces. `--summary` prints only the summary; `--raw` prints the plain diff of the unsplit lines, DSL positions included.

A compile error is printed as the compiler prints it, after a line saying which side ("before" or "after") did not compile, and exits 2. Identical crates print one line and exit 0; a difference exits 1.

## Deploying the emitted crate

The crate `axum_dsl build` writes is a plain cargo project; `cargo build --release` makes the binary.

- **Working directory.** Run the binary with the crate directory as its working directory. A `static`
  mount, a `serve_file` and a `file` are opened by the relative path they were declared with, and the
  compiler copied them into the crate at that path.
- **`PORT` and `BIND`.** The service reads the environment variables `PORT` and `BIND` when it starts.
  They win over `set :port` and `set :bind`, which are the fallbacks (4567 and 127.0.0.1 when a file sets
  neither). A container usually wants `BIND=0.0.0.0`. A `PORT` that is not a number from 0 to 65535 is
  a message on stderr and exit status 2; nothing is bound.
- **Signals.** ctrl-c, and SIGTERM on unix, stop the service gracefully: it stops accepting connections,
  lets the requests in flight finish, and exits 0. There is no deadline, so an orchestrator's own
  kill timeout is the backstop.
- **Logging.** `use_layer :trace` logs one line when each request starts and one when its response is
  sent, at INFO, and installs the log subscriber that shows them (text lines on stdout, no colour codes).
  `set :log, :json` switches the subscriber to one JSON object per line (tracing-subscriber's `json`
  feature); `set :log, :text` is the default format. The level is `info`; `RUST_LOG` overrides it with
  tracing-subscriber's `EnvFilter` syntax (`RUST_LOG=warn`, `RUST_LOG=my_service=debug`), and a
  `RUST_LOG` it cannot parse falls back to `info`. `set :log` without `use_layer :trace` still installs
  the subscriber, for the `tracing` events of a `rust_file` or `rust_item`, but logs no request lines.
  The crate depends on `tracing` and `tracing-subscriber` (with `env-filter`, and `json` for
  `:json`) only when the file says `use_layer :trace` or `set :log`; a service with neither has no
  subscriber and no such dependency.
- **Behind a proxy.** The peer a service sees is the proxy. `use_layer :trace, forwarded: true` makes the
  request log name the first `X-Forwarded-For` entry instead, falling back to the peer. Only turn it on
  behind a proxy that sets or overwrites the header; a caller can otherwise write any address.
- **TLS** is not built into the compiler, and a proxy in front can still terminate it. To serve TLS from
  the binary itself, name a Rust type of your own: `set :listener, "tls::TlsListener"`, where `tls` is
  the `as:` of a `rust_file` that holds the type. The emitted `main` then calls
  `tls::TlsListener::bind((bind.as_str(), port)).await?` where it would have bound a `TcpListener`, so
  `PORT`, `BIND`, graceful shutdown and the routes are unchanged. The type is yours to write and cargo
  checks it, not the compiler: it provides `pub async fn bind(addr: (&str, u16)) -> std::io::Result<Self>`
  and implements `axum::serve::Listener` with `type Addr = std::net::SocketAddr` (the generated service
  reads the peer's address from it, through `ConnectInfo<SocketAddr>`). Bring the TLS crates in with
  `rust_crate`. `examples/tls.axum.rb` and `examples/rust/tls_listener.rs` do it with `tokio-rustls`, read
  the certificate and key paths from `TLS_CERT` and `TLS_KEY`, and serve only TLS: a plain `http://`
  request to the port gets no HTTP answer. A file that names a listener but no `rust_file` for it is
  refused.
