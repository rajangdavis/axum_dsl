# The console

_See also: [The command line](cli.md), [Database](database.md)._

`axum_dsl console app.axum.rb` is a typed counterpart of `rails console` for the queries a service declares. It is
read-only and takes named queries only (slice 1): no raw SQL, no writes.

```
$ axum_dsl console examples/notes.axum.rb --db notes.sqlite3
axum_dsl console: read-only; lines are typed by the axum_dsl compiler and decoded at run time, not checked by rustc
3 queries (.queries lists them, .help the commands)
console> recent_notes(limit: 2)
SELECT id, body, created_at, tag FROM notes ORDER BY id DESC LIMIT :limit
=> [{id: i64, body: string, created_at: string, tag: string?}]
id  body           created_at  tag
--  -------------  ----------  ----
 2  hello console  2026-11-13  NULL
 1  first          2026-11-12  NULL
2 rows, 0.21 ms
```

## What checks what

A line is `name(arg: value, ...)`, `name arg: value` or `q :name, arg: value`. It is parsed, never evaluated, and
arguments are literals: numbers, strings, `true`, `false`, `nil`. Before anything is sent the compiler's declarations
check the query name (a misspelling gets "did you mean") and every argument: a name the query does not declare, a
missing one, a value that is not the declared type. The binary then decodes the answer at run time. Nothing is checked
by rustc, which is why the banner says so. An `execute` is refused on the Ruby side; any statement the binary finds not
`readonly()` (a `query` that is an `INSERT ... RETURNING`, say) is refused there, and the connection is `query_only`
besides.

The commands: `.queries` (name, arguments, row type), `.sql NAME` (render only), `.schema [TABLE]` (the tables the DSL
declares), `.why NODE` and `.impact NODE` (the [type graph](cli.md), the same as `axum_dsl graph`), `.more` (the next
20 rows; a result shows 20), `.help`, `.quit`.

## The wire protocol

`BINARY --console DB_PATH` is argv-gated in main like `--schema-check` and is emitted with every database. It opens
the file with the same connection setup as the server, makes the connection `query_only`, and **refuses** (exit 2, the
file names on stderr) a database whose migrations are not all applied with the recorded checksum; run the server once
to apply them. Then it writes `{"ready": true, "statements": N}` and loops: one JSON request per stdin line, one JSON
response per stdout line.

```
{"stmt": "recent_notes", "args": {"limit": 2}}
{"columns": ["id", "body", ...], "rows": [[2, "hello console", ...], ...], "ms": 0.21}
{"error": "statement `add_note` writes, and the console is read-only"}
```

SQLite values map to JSON: NULL, integer, real (a NaN is null), text, and a blob as the string `<blob, N bytes>`.
Arguments bind to the statement's named parameters; a missing or extra argument is an error.

## Not yet (what Rails does that this does not)

Writes (`--write`, one transaction per line), expressions and chains on the result, model objects and associations
(`Room.find(1).messages`), a list field of a record (the console shows the statement's columns, it does not run the
sub-queries that fill a record's list fields), history across sessions and completion (a plain line read, `Reline` only
when you add it), `reload!`, and running against a live reloaded app.

## Layout

`lib/axum_dsl/console.rb` is the Ruby side (line parser, catalog, table, REPL, child process) and
`lib/axum_dsl/console_rust.rb` the Rust the binary carries; neither reaches into the rest of the compiler beyond the IR,
`Suggest`, `CargoBuild` and `TypeGraph`, so both can move into a framework extraction. `test/test_console.rb` tests
the line checker and the REPL against a stand-in binary, the emitted Rust, and (with cargo and `sqlite3`) the real
binary on `examples/notes.axum.rb`.
