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
  `:f64`, `:bool`) or `:time` ([below](#time-fields)); `optional: true` marks a column that may be NULL; `list(:Other), from: :query` is a list of
  other rows ([below](#a-list-inside-a-record)). No other `field` option applies. A record
  is read in a body like any object a `params` group declares: `note.body`, `notes.map { ... }`, `note&.tag`
  on a nil-able one, and `json(note)`. A `def` in the block is a method of the row
  ([below](#record-methods)).
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

## A list inside a record

A row can carry a list of other rows, such as a message with its boosts. A `list(:Record)` field names, with
`from:`, the query that fills it:

```ruby
record :Boost do
  field :id, :i64
  field :content, :string
end

record :Message do
  field :id, :i64
  field :body, :string
  field :boosts, list(:Boost), from: :boosts_of   # not a column
end

query :boosts_of, args: { id: :i64 }, returns: list(:Boost), sql: "SELECT id, content FROM boosts WHERE message_id = :id ORDER BY id"
query :messages, args: {}, returns: list(:Message), sql: "SELECT id, body FROM messages ORDER BY id"
```

Whenever `messages` (or any statement returning `list(:Message)` or `:Message?`) reads its rows, it then runs
`boosts_of` once for each row, on the same connection, and puts the answer in `boosts`. The sub-query's arguments
are the row's columns **of the same names and types** (`id` here), so there is no mapping to write. A view loops
over it as over any list field, `{% for b in m.boosts %}`, and a partial takes it as an argument
(`{{ partial :boosts, boosts: m.boosts }}`); `json(messages)` writes it as an array.

The list field is not a column, so the query selects only the record's columns and the startup check leaves the
field out. It costs one statement per row (a prepared, cached statement on an open connection, with no
thread hand-off). Refused: a list field without `from:`, `from:` on a column, a name that is not a query, a query
that does not return `list(:Element)`, an argument that is not a non-optional column of the record with the same
type, and an element record that has list fields of its own (one level). A sub-query that no body calls gets no
async wrapper; one that is also called from a body gets one as usual.

## Record methods

A `def` in a `record` block is a method of the row, a value computed from its fields and read like a field:

```ruby
record :BoostRow do
  field :id, :i64
  field :booster_name, :string
  field :content, :string

  def label = "#{booster_name} boosted #{content}"
  def first_name
    booster_name.split.first || ""
  end
end
```

`row.label` in a body, and `{{ b.label }}` or `{% if b.flag %}` in a view, wherever a field of a record can be read
(a loop variable, an element of a list field, a `from:` record). The body is the [body language](body-language.md);
it reads the row's own fields by bare name (an `optional: true` field is nil-able there, as everywhere) and may call
the record's other methods by bare name. The result type is inferred, as a helper's is, and is a string, an integer,
a number or a bool (a nil-able one when the value may be nil, which a view marker then refuses as it does a nil-able
field).

A method is pure: a `query` or `execute`, `current`, `setting`, `params`, a helper, a binding, `rust(...)`, `render`,
`halt`, `redirect`, `raise` and `return` are refused in it, and so is a method that reaches itself, directly or
through others. A method takes no parameters yet (refused). A name is a field or a method, never both, and a method
is declared once. Methods are not columns: `json(row)` leaves them out, and the startup column check and
`--schema-check` ignore them. A record derived from a relation has none. In Rust a method is a function of the row's
struct (`impl BoostRow { fn label(&self) -> String }`) and costs nothing to a record that declares none.

## Time fields

SQLite stores Rails timestamps as text, `YYYY-MM-DD HH:MM:SS.ffffff` (UTC; the fraction may have 3 or 6 digits or be
absent). A `record` or `table` field of type `:time` (`optional: true` allowed) is that column: it is read as text and
held as a `String` in the emitted struct, so `json(row)` writes the stored text unchanged, `{{ u.updated_at }}` in a
view prints it like a string field, and the startup column check and `--schema-check` treat it as a string column. A
relation query may fill a `:time` record field from a `:string` or a `:time` table column and a `:string` record field
from a `:time` one; a record derived from a relation keeps the table's declared type.

```ruby
record :SidebarUser do
  field :id, :i64
  field :name, :string
  field :updated_at, :time

  def avatar_version = updated_at.to_fs(:number)   # "20250101093000", as Rails' Time#to_fs(:number)
end
```

In a body, a record method or a def, a `:time` value has these methods and no others (anything else is refused with
this list): `to_fs(:number)` is the 14 digits `YYYYMMDDHHMMSS` (`strftime('%Y%m%d%H%M%S', x)` in SQLite),
`iso8601` is `YYYY-MM-DDTHH:MM:SSZ`, `to_ms` is the milliseconds since the Unix epoch as an `:i64` (whole seconds plus
the fraction rounded to the nearest millisecond as SQLite does, a carry into the next second included; 0 when the text does not parse), `to_s` is the stored text, and `==` / `!=` compare
with another `:time`. A malformed text never panics. Each conversion is a small private Rust function, written into the
crate only when some body calls it. A nil-able `:time` has `nil?` and `to_s` (nil is `""`), as a nil-able string has.
A `:time` is not a `params` field type, an `args:` type, or a `returns:` scalar; a view marker writes it, but calls
methods on it only in the body.

## Placeholders

A placeholder is `:name`. SQLite binds it natively, so the SQL is emitted unchanged and bound with rusqlite's
named parameters. At compile time the compiler reads the SQL for placeholders, skipping `'strings'`,
`"quoted identifiers"`, `-- line` and `/* block */` comments (`::` is not a placeholder), and refuses:

- a `:name` that `args:` does not declare, and an argument that no `:name` uses;
- `?`, `?NNN`, `$name` and `@name`, with a message that says to write `:name`.

## Calling a statement

A body calls a statement as `name(arg: value)`. Keyword arguments only; every declared argument is passed
once and none is extra; each value fits its type. The call waits for the statement and, if the statement
fails (the database says so, or the writer or reader thread is gone), the request fails the way `raise` does:
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

Before the server accepts a connection it opens the writer thread's connection and, on it:

1. sets `PRAGMA journal_mode=WAL`;
2. applies the migrations that have not been applied;
3. prepares every declared statement, so SQL the database rejects (a missing table, a misspelled column)
   stops the server, and checks that a statement returning `list(:R)` or `:R?` selects exactly the fields of
   `R`, by name and as a set (their order does not matter), and that a scalar statement returns a column.

Any failure prints a message and exits with status 2. A column mismatch names the DSL file and line of the
query, the columns the record is missing and the columns that are not fields of it.

## Checking queries at build time

A wrong column name need not wait for a server and a database. `axum_dsl schema-check app.axum.rb` (or `make schema-check`
for the examples) builds the service and runs the binary with `--schema-check`, which is the startup above on a fresh
in-memory database: it applies the migrations, prepares every statement and compares each record's columns, with the same
messages. It exits 0 (`schema-check: ok, N statement(s) prepared`), or 2 after printing the message. It reads no settings,
binds no port, starts none of the writer, reader or checkpointer threads and leaves no file, so it needs no environment
and no production database. The schema is the `migrations` folder, so an app whose tables come from elsewhere cannot be
checked this way. It needs cargo (the check is the emitted Rust, so what it finds is what the server would), which is why
it is not part of `axum_dsl check`; `make e2e-schema-check` pins it (`test/e2e_schema_check.sh`).

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
BEGIN; compute the value before the block and pass the local. A value a controller `before ... provides:` filter provided
is computed before the action runs, so it reads there as a local does (`user.id`). In Rust the block
is a `move` closure, so a value it uses is moved into it: a route that needs the same value afterwards must
clone it or compute it outside the block. The block is refused in a file with no `database`, refused when
nested, and refused for anything that is not SQL: `return`, `raise`, a guard clause or any other statement.
A `return` would leave the block without its rollback, and non-SQL work does not belong in a
retried/rolled-back unit.

## SQL functions

A statement may call one function SQLite does not have: `action_text_attachable_ids(html, 'User')`, the ids the
`sgid`s of an Action Text body's `<action-text-attachment>`s name for the given model, as a JSON array text such as
`[3,7]` (each id once, in order of appearance; `[]` for a body with none or with a different model). It is for the
query that finds who a message mentions, `SELECT ... FROM users WHERE id IN (SELECT value FROM
json_each(action_text_attachable_ids(:body, 'User')))`. The sgid is decoded without a signature check (see
[Views](views.md#attachments-and-sounds)). The compiler registers the function (a deterministic scalar function with two
arguments) on every connection (the writer's and the readers') only when some statement's SQL contains `action_text_attachable_ids(`,
and the crate's `rusqlite` has the `functions` feature on either way; a crate whose SQL never calls it has no
sgid-decoding Rust and no registration.

## Tables

```ruby
table :rooms do
  field :id, :i64
  field :name, :string, optional: true
  field :type, :string
end
```

A `table` declares one table of the database: its columns, in order, each a `field` with a scalar type
(`:string`, `:i64`, `:f64`, `:bool`), and `optional: true` for a column that may be NULL. It is the schema source
for the coming model layer; for now it only fills a registry (`Db::Schema`, kept in the IR under `"tables"`) and
emits no Rust and no statement. It does not replace `record`: a `query` still returns a `record` (hand-written, or
derived from a relation query, see [below](#queries-as-relations)), and an unused `table` is not refused. A column name may be a Rust keyword (`type`), since a table emits no struct.

`id` is the primary key and may not be `optional: true`. A table declared twice, a column declared twice, a
table with no fields and a column type outside the four scalars are refused. Like a `record`, a `table` is written
at the top level or inside a `model`.

## Models

```ruby
expr :now, type: :string, sql: "strftime('%Y-%m-%d %H:%M:%f', 'now')"
expr :user_title, of: :t, type: :string,
     sql: "CASE WHEN COALESCE({t}.bio, '') = '' THEN {t}.name ELSE {t}.name || ' - ' || {t}.bio END"

model :Room, table: :rooms do
  has_many :memberships, dependent: :delete_all
  has_many :messages, dependent: :destroy
  has_many :users, through: :memberships
  has_many :rich_texts, table: :action_text_rich_texts, as: :record, dependent: :delete_all
  has_one :search_row, table: :message_search_index, foreign_key: :rowid, dependent: :delete_all
  belongs_to :creator, model: :User, foreign_key: :creator_id
  scope :directs, -> { where(type: "Rooms::Direct") }
  scope :visible_to, ->(uid) { joins(:memberships).where(memberships: { user_id: uid }) }
end
```

These are declarations only: they are read, checked and kept (`Db::Models`, in the IR under `"models"` and
`"exprs"`), and they emit no Rust. A `query` or `execute` written as a relation uses them ([below](#queries-as-relations));
a model or an `expr` nothing uses is not refused.

**The model.** `model :Room` (or `model "Account::Bot"`; the name still comes from the file under `models/` when it is
left out) may say `table:`, the declared `table` it owns. The compiler has no inflection (`:Room` is not turned into
`rooms`), so `table:` is required once the model declares an association or a scope; a model that only holds records,
queries and defs needs none. A `table:` that names no declared table is refused with the nearest declared one.

**Associations.** `has_many`, `has_one` and `belongs_to` take `through:`, `dependent:` (`:destroy` or `:delete_all`),
`table:`, `model:`, `foreign_key:` and `as:`. The target is `model:` (its table), else `table:`, else, for a
`has_many`, the association's own name; a `has_one` or `belongs_to` names `model:` or `table:`. The foreign key is
`<model underscored>_id` on the target table for `has_many` and `has_one`, `<name>_id` on the model's own table for
`belongs_to`, unless `foreign_key:` says otherwise; `as: :record` (a polymorphic child) uses the columns `record_type`
(the model's name) and `record_id`. `through:` names another association of the same model; the model it reaches
must declare the association by the same name or its singular (`has_many :users, through: :memberships` reads
`:user` or `:users` of Membership), and it takes no table, model, key or `dependent:` of its own. `dependent:` is for
`has_many` and `has_one` only. Once the whole file is read, a missing model, table or column, an association
declared twice and a name shared by an association and a scope are each refused, naming the model, the association
and the missing thing. `Db::Models#association(model, name)` answers the resolved association and
`destroy_plan(model)` the tree `Db::Rel.destroy` takes, from the `dependent:` declarations in declaration order; a
cycle of `dependent: :destroy` is refused.

A `has_one` may carry a fixed condition, as Rails writes it: `has_one :body_text, -> { where(name: "body") }, table:
:action_text_rich_texts, as: :record`. The lambda holds one `where(column: literal, ...)` on the association's own table
(a string, integer, `true` or `false`) and nothing else. The conditions become part of the ON clause of `joins` and
`left_joins` (so a left join keeps the rows that have no match) and of the subquery of `where_exists`, after the keys and
the polymorphic type: `LEFT OUTER JOIN action_text_rich_texts ON action_text_rich_texts.record_id = messages.id AND
action_text_rich_texts.record_type = 'Message' AND action_text_rich_texts.name = 'body'`. It does not take `dependent:`
(what `destroy` should delete is not said then; declare a second association without the lambda for that) or `through:`,
and a column the table lacks is refused. `has_many` and `belongs_to` take no lambda.

**Scopes.** `scope :name, -> { ... }` or `scope :name, ->(a, b) { ... }`, inside a `model` only (at the top level
`scope path:` is still the route prefix). The lambda is kept as written, its parameter names and its body, and is not
evaluated or checked yet. The parameters are plain required names, the lambda is not empty, the name is unique in the
model, and it is neither an association nor a relation operation (`where joins left_joins select order limit first all pick count
exists insert update update_all touch delete destroy where_not where_exists where_not_exists or last offset distinct insert_from`). `scope(:name) { }` is refused.

**Expressions.** `expr :name, type: :string, sql: "..."` names a piece of SQL of a scalar type (`:string`, `:i64`,
`:f64`, `:bool`). With `of: :t` the sql writes the table it applies to as `{t}` (at least once, and no other
`{name}`); without `of:` it has no `{...}`. It has no `?` placeholder. A `:name` placeholder is allowed only for a bind the
declaration lists, `args: { user_id: :i64 }` (scalar types), and every listed bind must appear in the sql:

```ruby
expr :is_current, of: :t, type: :bool, args: { user_id: :i64 }, sql: "CASE WHEN {t}.id = :user_id THEN 1 ELSE 0 END"
```

A relation gives each bind by name where it uses the expr, `expr(:is_current, user_id: arg(:user_id))` (after the joined
table, if any: `expr(:name, :assoc, bind: value)`). A bind is an `arg(:x)` of the statement, a string, integer or
boolean literal, or another `expr`, of the declared type; the SQL keeps the statement's own `:x` placeholder, so the
argument is bound once as usual. An unknown bind, a missing one, a bind given to an expr that declares none, a bind of
the wrong type and `nil` are each refused at the call. A top-level name is declared once.

**Whose expression.** An `expr` written inside a `model` is that model's own: `{t}` is the model's table (`of:` is implied), and the
same name on two models is two exprs. An expr that several models share goes in a `concern`, as in Rails (a file
`models/concerns/timestamps.axum.rb` that `use_dsl` includes):

```ruby
concern :Timestamps do
  expr :updated_ms, type: :i64, sql: "CAST(strftime('%s', {t}.updated_at) AS INTEGER) * 1000"
end

model :User, table: :users do
  include :Timestamps
  expr :title, type: :string, sql: "UPPER({t}.name)"
end
```

`include :Timestamps` makes the concern's exprs the model's. `expr(:name)` in a relation of a model looks at the model's own exprs,
then those of the concerns it includes (in include order), then the top-level ones; `expr(:name, :assoc)` does the same for the model
that owns the joined table, so that model includes the concern too. The include line is refused when the concern is unknown (with a
"did you mean"), when the model's table lacks a column the concern's exprs read as `{t}.column` (the message names the concern, the
expr, the table and the column), when the concern is included twice, and when two included concerns have an expr of one name. An expr
that exists only in a concern the model did not include says so: "`x` is in concern `C`; add `include :C` to `M`". A model's expr may
not take the name of a top-level expr or of an included concern's, and a concern is not named like a model. In
`insert_from(Blob.where(...), ...)` the values are read in the source model's frame, so a `column: expr(:x)` there is an expr of `Blob`.
The type graph and the hover name an expr with its owner, `expr:User.title`; an included one is `expr:User.updated_ms`, derived from
`expr:Timestamps.updated_ms` by the rule `include`, and hovering the `include` line lists them.

### Queries as relations

A `query` or `execute` inside a `model` that names its `table:` may take a block instead of `sql:`: exactly one of the
two (both, or neither, is refused). The block is ONE expression, a method chain whose implicit receiver is the model's
own relation. The compiler reads it, renders one SQLite statement from it, and hands that to the same pipeline as a
statement written with `sql:`, so the Rust, the startup check, the placeholder rules and the OpenAPI are the same;
the file's `record`s, `args:` and `returns:` mean what they always do.

```ruby
model :Room, table: :rooms do
  has_many :memberships
  scope :visible_to, ->(uid) { joins(:memberships).where(memberships: { user_id: uid }) }

  query :room_for_user, args: { user_id: :i64, id: :i64 }, returns: :RoomName? do
    visible_to(arg(:user_id)).where(id: arg(:id)).select(:id, name: coalesce(:name, ""))
  end
  query :room_count, args: {}, returns: :i64 do
    count
  end
  execute :touch_room, args: { id: :i64 } do
    where(id: arg(:id)).touch
  end
end
```

The operations, and nothing else:

- `where(col: value, ...)`, and `where(association: { col: value })` for an association (or its table) that an earlier
  `joins` joined; `where_not(...)` takes the same forms. `where(gt(:col, v))`, `gte`, `lt`, `lte` and `like` compare
  (no operators); the left side is a column, `col(:assoc, :column)` or a declared expression, `where(gt(expr(:name), arg(:x)))`
  (`expr(:name, :assoc)` for a joined table's, as in `select`); `where_not` takes `column: value` pairs only.
  A declared `:bool` expression is itself a condition, `where(expr(:visible_status, include_banned: arg(:b)))`, rendered
  parenthesised, and `where_not(expr(:name))` negates it (`NOT (...)`); it also goes inside `or(where(...))`. An expr of
  another type is refused.
- `where(...).or(where(...))`, as Rails: every condition so far is the left side, the argument's conditions (ANDed) the right
  side, and the two are parenthesised and joined with OR; conditions added after it are ANDed with the whole. The
  argument is a chain written with the implicit receiver of `where`, `where_not`, `where_exists`, `where_not_exists`
  and scopes that only add conditions, nothing else (no `joins`, `select`, `order`, `limit`, no end of the chain, no
  second `or`), and `or` needs a condition before it. `arg(:name)` in it counts as a use.
  ```ruby
  where(status: 0).or(where(status: 2, role: arg(:role)))
  # WHERE (status = 0) OR (status = 2 AND role = :role)
  where(status: 0).or(where(status: 2)).where(role: arg(:role))
  # WHERE ((status = 0) OR (status = 2)) AND role = :role
  ```
- `where_exists(:association, col: value, ...)` and `where_not_exists(...)` (EXISTS and NOT EXISTS, [below](#subrelations)).
- A value is `arg(:name)` (declared in `args:`; every declared argument must be used somewhere), a string, integer,
  `true`, `false` or `nil` literal (`col: nil` is `IS NULL`), a list of such literals (`IN`), a [subrelation](#subrelations),
  or `in_ids(arg(:ids))`
  (`id IN (SELECT value FROM json_each('[' || :ids || ']'))`; the argument is a `:string` of comma-separated ids).
- `joins(:association)` for a `has_many`, `has_one` or `belongs_to` of the model, with its polymorphic `as:` columns;
  a `through:` association joins both tables. `left_joins(:association)` takes the same associations and renders `LEFT OUTER JOIN`
  (a through association left-joins both tables); `where(association: { col: value })` and `col(:association, :column)` work
  as for `joins`. A column of a left-joined table may be NULL, so it is optional wherever the type of a selected value
  matters (a field of a [derived record](#queries-as-relations) is `optional`) unless it is wrapped in `coalesce`.
- `select(:col, :col2, alias: expression)`; an expression is `:col`, `coalesce(:col, literal)` (or `coalesce(col(:assoc, :column), literal)`, or `coalesce(expr(:name), literal)` /
  `coalesce(expr(:name, :assoc), literal)`: the result is never NULL, so it is not optional even over a left-joined table), `col(:assoc, :column)`
  for a joined table's column, or `expr(:name)` / `expr(:name, :assoc)` for a declared `expr`. Without `select` the
  rows are all the table's columns. A value may also be a literal, only under a name: `select(:id, active: true, banned: false,
  source: "web", rank: 1)` renders `1 AS active, 0 AS banned, 'web' AS source, 1 AS rank`. It is typed from the literal (a string is
  `:string`, an integer `:i64`, `true`/`false` `:bool`, never optional); `nil`, a float and an unnamed literal are refused.
- `order(:col)`, `order(col: :desc)`, `order(col: :nocase)` (ascending, ignoring case: `COLLATE NOCASE`); a joined table's column
  `order(col(:assoc, :column))` and `order(col(:assoc, :column) => :desc)`, a declared expression `order(expr(:name))`,
  `order(expr(:name, :assoc) => :desc)` (`:asc`, `:desc` or `:nocase` after `=>` as after `col:`); `limit(n)` and `limit(arg(:n))` (an `:i64` argument).
- `last(n)` and `last(arg(:n))`, as Rails' `Message.ordered.last(40)`: the last n rows of the relation's order, handed back in
  that order. It needs an `order` and is refused with `limit` (it is the limit), with `offset`, with `distinct`, in a
  subrelation, and in a `query` that does not return `list(:Record)`. It renders the order reversed with the limit in an
  inner SELECT, and an outer SELECT puts the rows back in the declared order. Every order term (a column, a joined
  column, an `expr`) is also selected in the inner query under a private alias (`_o1`, `_o2`, ...) for the outer sort,
  so the record does not gain a field.
  ```ruby
  order(:created_at, :id).last(arg(:n)).select(:id)
  # SELECT id FROM (SELECT id, created_at AS _o1, id AS _o2 FROM messages ORDER BY created_at DESC, id DESC LIMIT :n)
  # ORDER BY _o1, _o2
  ```
- `offset(n)` and `offset(arg(:n))` (a non-negative integer or an `:i64` argument), after `limit`: `limit(10).offset(20)` is
  `LIMIT 10 OFFSET 20`. Refused without a `limit` before it.
- `distinct`: `SELECT DISTINCT`. It is for the rows of a `query`, a subrelation and the source of `insert_from`; `count`
  and `exists` refuse it, and an `execute` that changes rows refuses it, `last` and `offset`.
- A scope of the model by name with its arguments, `visible_to(arg(:user_id))`: its lambda is inlined, its parameters
  bound to the values given, where a value may stand. A scope may call other scopes, not itself.
- A `pick` of an aggregate: `pick(group_concat(:col))` is `group_concat(col)` (comma-separated, SQLite's default) over the whole
  relation, which is always exactly one row, but NULL when no row matches, so it is `:string?`.
  `pick(coalesce(group_concat(:col), ""))` can not be NULL, which the compiler derives (an aggregate with no `GROUP BY`
  gives one row; `coalesce` with a literal removes the NULL), so it is the one `pick` allowed `returns: :string` (not `:string?`).
  It renders with no `LIMIT`, and takes no `order`, `limit`, `offset` or `distinct`. Any other `pick` stays optional, and a
  `returns:` that is not says so and names this form. `group_concat` takes one column (`:col` or `col(:assoc, :column)`)
  and is only the value of a `pick`: in a `select` it is refused. In Campfire:

  ```ruby
  query :message_blob_ids, args: { message_id: :i64 }, returns: :string do
    where(record_type: "Message", record_id: arg(:message_id)).pick(coalesce(group_concat(:blob_id), ""))
  end
  # SELECT COALESCE(group_concat(blob_id), '') FROM active_storage_attachments WHERE record_type = 'Message' AND record_id = :message_id
  ```
- The end of the chain. For a `query`: nothing (the rows; `returns: :Record?` is the first row and `list(:Record)` every
  row, so `first` and `all` are not written), `count` (`:i64`), `exists` (`:bool`), `pick(:col)` or `pick(expr(:name))` (the column's or the expr's type with
  `?`), or `insert(col: value, ..., returning: :id)` alone (the column's type). For an `execute`: `touch`, `delete`,
  `destroy`, `update(col: value, ...)` (moves `updated_at` too when the table has it and a value changes), `update_all(col: value, ...)` (does not; `col: nil` writes `col = NULL`, refused for a column that is not nil-able),
  `insert(col: value, ...)` or `insert_from(Model.where(...), col: value, ...)` ([below](#insert-from-another-relation)). `destroy` is described [below](#destroy). `insert` takes `on_duplicate: :skip`
  (Rails' `insert_all(..., on_duplicate: :skip)`), which renders `INSERT OR IGNORE INTO` and changes nothing else, `returning:`
  and the timestamps included; any other value is refused. `insert_from` is [below](#insert-from-another-relation).

`created_at` and `updated_at` are stamped by `insert` when the table has them; `update` moves `updated_at` only when one of
its values differs from the row's (as Rails' `update` does: `updated_at = CASE WHEN col IS NOT value ... END`), `touch` always. A relation `query` that returns a
record needs the record to have exactly the fields the relation selects, by name, type and optionality (the order does
not matter, as the startup check matches columns by name); a mismatch is refused naming the field and both types. Two
type differences are not mismatches: a `:time` field may be filled by a `:string` value and the other way round, and a `:bool` value
(an `expr ... type: :bool`, a `:bool` column, a `true`/`false` literal) may fill an `:i64` field, since SQLite already holds a boolean
as 0 or 1 and the SQL is unchanged. It does not work the other way: an integer is not always 0 or 1, so an `:i64` value for a
`:bool` field is refused.

**A derived record.** A relation `query` may name a record that no `record` declares: `returns: :RoomName?` or
`returns: list(:RoomName)` with no `record :RoomName` anywhere. The compiler then declares it from the fields the
relation selects (name, type and optionality, in selection order, so a column that may be NULL is an `optional: true`
field), at the place of the first relation query that names it, exactly as if you had written the `record` block
there: the Rust struct, the startup check and every use of a record are the same as for a declared one. Several
relation queries may name the same derived record when they select the same fields in the same order; if not, the
second is refused, naming both queries and the first field that differs. A derived record can be returned by a
handler, rendered, or named by a `sql:` query's `returns:` like a declared one (that query is then checked against it as
always). A `sql:` query never derives: its unknown record is still refused as "not declared". When a record of the
name is declared, it is matched as described above and nothing is derived. There is only the `:Record?` (first row or
nil) and `list(:Record)` form; a bare `:Record` is not a `returns:`.

### Subrelations

Where a `where` value may stand, another model's relation may too: the model's constant, a chain of the operations
above (`where`, `where_not`, `where_exists`, `joins`, that model's scopes, `order`, `limit`, `offset`, `distinct`), and a `select` of exactly
one value (`select(:col)` or `select(alias: expression)`) as the last step. It renders a subquery in the WHERE clause.

```ruby
model :Room, table: :rooms do
  execute :touch_rooms_of, args: { user_id: :i64 } do
    where(id: Message.where(creator_id: arg(:user_id)).select(:room_id)).touch
  end
  execute :purge_unattached, args: { ids: :string } do
    where(id: in_ids(arg(:ids))).where_not(id: Attachment.select(:blob_id)).delete
  end
  query :older_ids, args: { id: :i64 }, returns: list(:RoomId) do
    where(lt(:created_at, Room.where(id: arg(:id)).select(:created_at))).select(:id)
  end
end
```

- `where(col: Sub)` is `col IN (SELECT ...)`, `where_not(col: Sub)` is `col NOT IN (SELECT ...)`, and
  `where(lt(:col, Sub))` (`gt`, `gte`, `lte` too; not `like`) is a scalar comparison, `col < (SELECT ...)`.
- The constant must be a declared model with a `table:`; the model's own constant is allowed (the subquery has its own
  scope for its columns, so nothing collides). `arg(:name)` in it is the statement's argument and counts as used.
  A subrelation ending in anything but one selected value, ending in `count`, `pick`, `insert` and the like, or written
  inside a scope, is refused; an unknown constant gets a "did you mean".
- The selected column's type is not compared with the type of the column it is compared with.

`where_exists(:association, col: value, ...)` is `EXISTS (SELECT 1 FROM target WHERE ...)` over an association of the
model (`has_many`, `has_one`, `belongs_to`, polymorphic `as:` included); the rows are correlated by the same keys
`joins(:association)` derives its ON clause from, and the `col: value` pairs (a value as `where` takes it) are
conditions on the association's table. `where_not_exists` is `NOT EXISTS`. A `through:` association is refused (use the
association it goes through).

```ruby
where_exists(:memberships, user_id: arg(:uid))
# EXISTS (SELECT 1 FROM memberships WHERE memberships.room_id = rooms.id AND memberships.user_id = :uid)
```

When the association's table is the statement's own, the inner one is aliased `<table>_exists`.

### Insert from another relation

Rails has no single-statement form of INSERT ... SELECT; `insert_from` is ours. It is the whole chain of an `execute` in the
model that owns the TARGET table, and takes another model's relation and `target_column: value` pairs:

```ruby
model :Membership, table: :memberships do
  execute :grant_room_to_active_users, args: { room_id: :i64 } do
    insert_from(User.where(status: 0), room_id: arg(:room_id), user_id: :id, involvement: "mentions", on_duplicate: :skip)
  end
end
# INSERT OR IGNORE INTO memberships (room_id, user_id, involvement, created_at, updated_at)
# SELECT :room_id, id, 'mentions', strftime('%Y-%m-%d %H:%M:%f', 'now'), strftime('%Y-%m-%d %H:%M:%f', 'now') FROM users WHERE status = 0
```

- The first argument is a [subrelation](#subrelations) read as it is there (another model's constant, alone or followed by
  `where`, `where_not`, `where_exists`, `joins`, `left_joins`, that model's scopes, `order`, `limit`, `offset`, `distinct`),
  but WITHOUT a final `select`: the selected values are the pairs. A `select`, an end of the chain and `last` are refused.
- A value is read in the source model's frame: a Symbol is a column of the source table (`user_id: :id`), `col(:assoc, :column)`
  a column of a table the source joined, `expr(:name)` / `expr(:name, :assoc)` a declared `expr` on the source, and anything
  else is what `insert` takes (`arg(:x)`, a string, integer or boolean literal; not `nil`). The values are not type-checked
  against the target columns, as `insert` does not.
- `created_at` and `updated_at` are appended when the target table has them and no pair gives them, as `insert` appends
  them. `on_duplicate: :skip` renders `INSERT OR IGNORE INTO`.
- Refused, each naming the thing: an unknown target column, an unknown source column, a column given twice, `returning:`, a
  call in a `query`, anything before it in the chain, no pair, and a pair given as anything but `column: value`. Required
  columns are not checked (`insert` does not check them either): the database refuses a NULL in a NOT NULL column when
  the statement runs.

### destroy

`execute :destroy_room, args: { id: :i64 } do where(id: arg(:id)).destroy end` deletes the rows the relation names and
what their model's `dependent:` associations say goes with them (`:destroy` recursively, `:delete_all` as one
DELETE), in the order `Db::Rel.destroy` renders them from `Db::Models#destroy_plan`: the dependents of each row first,
the root's DELETE last. For the `Room` example above that is seven statements. They are ONE statement of the file
(`destroy_room`) that runs them in that order on one connection, and the number the call answers is the root DELETE's
row count. Because they must stand or fall together, a destroy with dependents is called only inside a
`transaction do ... end`; calling it anywhere else is refused with the spelling to write:

```ruby
post "/rooms/destroy" do
  rows = transaction do
    destroy_room(id: 1)
  end
  text(rows.to_s)
end
```

Nothing is hidden: the compiler prints the notice `N-DESTROY` at the declaration, listing the statements in order
(see [notifications](notifications.md)), and `axum_dsl schema-check` prepares every one of them. A model with no
`dependent:` association destroys with the single DELETE `delete` renders, so that is an ordinary statement: it may be
called anywhere and prints no notice. `destroy` takes no arguments (`returning` is not supported), has no joins, and a
`query` cannot end in it. A `through:` association takes no `dependent:`, so only `has_many`/`has_one` (plain, with
`foreign_key:` or polymorphic `as:`) add statements.
A block, an unknown method, a splat, a local variable or string interpolation is refused, naming the call and what is
allowed there, and an unknown column, association, scope or `expr` gets a "did you mean". A relation is read once the
whole file is, so a scope or `expr` may be declared below the statement that uses it.

### Attachments

Active Storage's `has_one_attached :avatar` in a `model` (the model names its `table:`, and the tables `active_storage_blobs`
and `active_storage_attachments` are declared, each owned by a model, whatever it is called):

```ruby
model :User, table: :users do
  has_one_attached :avatar
end

query :profile, args: { id: :i64 }, returns: :Profile? do
  where(id: arg(:id)).select(:name, avatar_attached: attached(:avatar))
end

patch "/profile", params: :ProfileForm do
  stored = params[:avatar]&.store_file(setting(:storage)) # a file write precedes the transaction; nil without a file
  transaction do
    attach(:avatar, params[:id], stored) # nil is a no-op
  end
  ...
end
```

It derives, as if written (each carries where it came from, `has_one_attached :avatar` and its line, in the IR as `derived`):

- `has_one :avatar_attachment, -> { where(name: "avatar") }, as: :record` and `has_one :avatar_blob, through: :avatar_attachment`,
  which `joins`, `left_joins` and `where_exists` take (a `through:` is refused by `where_exists`, as always).
- `attached(:avatar)`, a `:bool` value for `select` and a condition for `where` / `where_not`: `EXISTS (SELECT 1 FROM
  active_storage_attachments WHERE record_type = 'User' AND record_id = users.id AND name = 'avatar')`. It names an attachment
  of the statement's own model; an unknown name gets a "did you mean".
- Four statements, `insert_user_avatar_blob`, `detach_user_avatar`, `attach_user_avatar` and (when the table has `updated_at`)
  `touch_user_avatar`, ordinary relation statements of the models that own the tables. A hand-written statement of the same
  name is refused. `attach(:avatar, owner_id, stored)` is the one call that runs them: the blob row, the old attachment removed
  (one attachment, so a new file replaces the old), the attachment row and the owner touched, in that order, as one unit, so it
  is called inside a `transaction`. `fresh: true` is for an owner created in the same transaction: no old attachment to remove
  and no touch.

`stored` is `upload&.store_file(setting(:storage))` of an `:upload` field: `store` and the file as a typed `StoredFile` (`key`,
`filename`, `content_type`, `size`, `checksum`, `metadata`); `store` itself still answers the key alone. The compiler prints the
notice `N-ATTACHED` at the declaration, listing the statements and their SQL in order, and `schema-check` prepares every one.
Two models may not declare the same attachment name, since `attach(:avatar, ...)` names the attachment alone. Not there yet:
`purge`, variants, `has_many_attached`, and `attach` on a loaded record.
## What is not there

- **Other databases.**
 `:sqlite` is the only adapter. The SQLite-specific part is one module
  (`lib/axum_dsl/db/sqlite.rb`) that the emitter reaches through a few calls, which is where another adapter
  would go.
- **An ORM.** SQL is the interface; a relation block is another way to write the statement, rendered to SQL when the file is compiled.
- **Nil-able or list arguments**, and bound values other than the four scalar types.

The emitted crate gains `rusqlite` and `deadpool-sqlite` (both `bundled`, so SQLite is compiled in) only
when a file declares `database`. The writer and reader threads are process-wide, opened at startup the way `setting(:x)`
values are, so no handler takes extra state.

Writes and reads run on threads of their own, as in `once-campfire-rust/crates/db/src/database.rs`. One `db-writer`
thread owns one connection (set up like every other: the same pragmas, WAL hook and statement cache) and runs, in
arrival order and back to back, every statement that writes (decided at startup with `sqlite3_stmt_readonly`, so a
`RETURNING` write counts) and every `transaction do ... end` (opened IMMEDIATE, committed on success, rolled back
on an error). A caller sends the writer a boxed closure and awaits a oneshot reply, so no async lock is held across
a write; an error names the query or transaction, and a panic in a write is caught, answers its caller with an error
and leaves the writer running. After a write the writer notes the WAL growth and wakes the checkpointer. Reads go to
five `db-reader` threads, each with its own `query_only` connection.
