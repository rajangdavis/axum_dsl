# Database

_See also: [README](../README.md), [The DSL](dsl.md), [The body language](body-language.md), [Coverage](coverage.md)._

A service can keep state in a SQLite database. The design is SQL first: the SQL you write is the SQL that
runs, byte for byte. There is no ORM, no query builder and no query language of the DSL's own. The compiler
checks what it can without a database (the placeholders, the types, the calls); the server checks the rest
once, as it starts, against the real database. `examples/notes.axum.rb` is the worked example, and
`make e2e-notes` drives it.

```ruby
database :sqlite, path: "notes.sqlite3", env: "DATABASE_PATH"   # env, when set, replaces path at startup
migrations "notes/db/migrate"                                   # optional

record :Note do
  field :id, :i64
  field :body, :string
  field :created_at, :string
  field :tag, :string, optional: true      # a column that may be NULL
end

query :recent_notes, args: { limit: :i64 }, returns: list(:Note), sql: <<~SQL
  SELECT id, body, created_at, tag FROM notes ORDER BY id DESC LIMIT :limit
SQL

query :find_note, args: { id: :i64 }, returns: :Note?, sql: "SELECT id, body, created_at, tag FROM notes WHERE id = :id"

query :add_note, args: { body: :string }, returns: :i64, sql: <<~SQL
  INSERT INTO notes (body, created_at) VALUES (:body, datetime('now')) RETURNING id
SQL

execute :delete_note, args: { id: :i64 }, sql: "DELETE FROM notes WHERE id = :id"
```

A route or a filter body calls a statement by name with keyword arguments:

```ruby
get "/notes" do
  json(recent_notes(limit: 20))
end
```

## The declarations

- **`database :sqlite, path: "...", env: "..."`**: exactly one. The first argument is the adapter, and
  `:sqlite` is the only one (any other is refused: "`:postgres` is not an adapter yet; `:sqlite` is the
  only one"). `path:` is the file, relative to the directory the server runs in; `env:` names a variable that
  replaces it when it is set and not empty. A `database` that no `query` or `execute` uses is refused.
- **`record :Name do ... end`**: the row a query returns. Each `field` has a scalar type (`:string`, `:i64`,
  `:f64`, `:bool`); `optional: true` marks a column that may be NULL. No other `field` option applies. A record
  is read in a body like any object a `params` group declares: `note.body`, `notes.map { ... }`, `note&.tag`
  on a nil-able one, and `json(note)`.
- **`query :name, args: {...}, returns: ..., sql: "..."`**: a statement that reads. `returns:` is
  `list(:Record)` (every row), `:Record?` (the first row, or nil) or a scalar type (`:i64`, `:string`, `:f64`,
  `:bool`) read from the first column of the first row, with `?` (`:i64?`) when the answer may be nil: no row,
  or a NULL. A scalar without `?` and with no row is a request error, not a nil. A record the query returns
  must be declared in the file.
- **`execute :name, args: {...}, sql: "..."`**: a statement that changes data. It takes no `returns:`; a body
  gets the number of rows it changed, an `:i64`.
- **`migrations "folder"`**: the folder of `*.sql` files, relative to the DSL file (see below).

An argument is one of the scalar types. A `query`, an `execute` and a `record` that nothing uses is refused,
like an unused helper.

## Placeholders

A placeholder is `:name`. SQLite binds it natively, so the SQL is emitted unchanged and bound with rusqlite's
named parameters. At compile time the compiler reads the SQL for placeholders, skipping `'strings'`,
`"quoted identifiers"`, `-- line` and `/* block */` comments (`::` is not a placeholder), and refuses:

- a `:name` that `args:` does not declare, and an argument that no `:name` uses;
- `?`, `?NNN`, `$name` and `@name`, with a message that says to write `:name`.

## Calling a statement

A body calls a statement as `name(arg: value)`. Keyword arguments only; every declared argument is passed
once and none is extra; each value fits its type. The call waits for the statement and, if the statement
fails (the database says so, or the pool cannot give a connection), the request fails the way `raise` does:
the `error` filter answers, or a plain 500 whose message names the query. A statement may be called from a
route or a filter body, not from a helper or a binding body (the same rule as `setting(:x)`), and not from the
`error` filter, which answers a request that already failed.

A nil-able result follows the body language's rules for nil-able values (`|| default`, `|| raise`, `.nil?`,
`&.`; after `.nil?` the local is non-nil in the other branch), so a missing row is a 404 like this:

```ruby
get "/notes/:id", params: :NoteId do
  note = find_note(id: params[:id])
  if note.nil?
    halt(404, "no such note")
  else
    json(note)
  end
end
```

## Startup

Before the server accepts a connection it opens the pool and, on one connection:

1. sets `PRAGMA journal_mode=WAL`;
2. applies the migrations that have not been applied;
3. prepares every declared statement, so SQL the database rejects (a missing table, a misspelled column)
   stops the server, and checks that a statement returning `list(:R)` or `:R?` selects exactly the fields of
   `R`, by name and as a set (their order does not matter), and that a scalar statement returns a column.

Any failure prints a message and exits with status 2. A column mismatch names the DSL file and line of the
query, the columns the record is missing and the columns that are not fields of it.

## Migrations

`migrations "db/migrate"` names a folder of `*.sql` files. Their names must match
`\A\d+_[a-z0-9_]+\.sql\z` (`001_create_notes.sql`); any other `.sql` name is refused. They are applied in
file-name order, each in its own transaction, and each is recorded in a table the server creates:

```sql
axum_dsl_migrations(version TEXT PRIMARY KEY, sha256 TEXT NOT NULL, applied_at TEXT NOT NULL)
```

The version is the file name. The files are read at compile time and embedded in the binary, so they are
inputs of the compile (`--print-inputs` names them, `axum_dsl dev` watches them) and the running service
needs no folder. An applied migration whose text has changed stops startup with a message naming the file,
because the database no longer matches what the file says; write a new migration instead. The server touches
no other table, so a database that another tool owns (a Rails database, say) stays as it is.

## Transactions in a body

With a `database`, a body may run several statements on one connection inside a transaction:

```ruby
post "/messages" do
  message_id = transaction do
    id = add_note(body: params[:body])
    find_note(id: id)
    id
  end
  json(message_id)
end
```

`transaction do ... end` is a value: its final expression. Inside the block only a declared `query`/`execute`
call may stand: `name = statement(...)` declares a local, a bare call runs for its effect, and the last
expression is a statement call or a local. The calls run on the transaction's connection; a database error on
any of them rolls the whole block back, and success commits before the value comes back. A statement's
arguments are computed in that closure too, after BEGIN: they may only read values that already exist
(`params[:body]`, a local, a field read, a literal, or a list/hash/interpolation of those). A helper,
`rust(...)`, a binding, `current(...)`, a nested statement or any other call is refused there, because a
fallible call's error cannot cross the closure's `rusqlite::Result` and non-SQL work must not run after
BEGIN; compute the value before the block and pass the local. In Rust the block
is a `move` closure, so a value it uses is moved into it: a route that needs the same value afterwards must
clone it or compute it outside the block. The block is refused in a file with no `database`, refused when
nested, and refused for anything that is not SQL: `return`, `raise`, a guard clause or any other statement.
A `return` would leave the block without its rollback, and non-SQL work does not belong in a
retried/rolled-back unit.

## What is not there

- **Other databases.** `:sqlite` is the only adapter. The SQLite-specific part is one module
  (`lib/axum_dsl/db/sqlite.rb`) that the emitter reaches through a few calls, which is where another adapter
  would go.
- **An ORM or a query builder.** SQL is the interface.
- **Nil-able or list arguments**, and bound values other than the four scalar types.

The emitted crate gains `rusqlite` and `deadpool-sqlite` (both `bundled`, so SQLite is compiled in) only
when a file declares `database`. The pool is a process-wide value opened at startup, the way `setting(:x)`
values are, so no handler takes extra state.
