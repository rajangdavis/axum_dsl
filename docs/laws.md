# Laws

A law is a property the compiler turns into a [proptest](https://crates.io/crates/proptest) test in the
generated crate. `axum_dsl test FILE` builds the crate and runs them (`cargo test`).

```ruby
params :Pair do
  field :a, :i64, min: -1000, max: 1000
  field :b, :i64, exclusive_min: 0, max: 50
end

helper :add, args: [:i64, :i64], returns: :i64 do |a, b|
  a + b
end

law :add_commutes, forall: :Pair do |a, b|
  add(a, b) == add(b, a)
end

law :example_add do
  add(2, 3) == 5
end
```

- `forall:` names a params group. The block's parameters are fields of it, and each is generated within its
  declared constraints: `min:`/`max:`, `exclusive_min:`/`exclusive_max:` (integers), `enum:`, `pattern:`,
  `min_length:`/`max_length:`, `min_items:`/`max_items:`, `optional:` and `default:`. These are the constraints a
  request is checked against, so a law quantifies over exactly the inputs a route accepts. A group only laws use is
  allowed, and writes no struct.
- `cases:` sets how many inputs are tried (default 256). A law without `forall:` is an example law, run once.
- The body is compiled like a helper's and must end in `true`/`false`. A `raise`, or a checked-arithmetic error
  (integer overflow, division by zero), fails the law with that message.
- A failure names the law, its DSL line and the shrunk minimal input:

  ```
  law add_commutes (laws.axum.rb:24) does not hold: returned false
    minimal failing input: (0, 7)
  ```

- Runs are seeded per law, so they repeat exactly; `AXUM_DSL_SEED=<u64>` explores other inputs.
- Laws compile under `#[cfg(test)]`, and proptest is a dev-dependency, so the release binary carries neither. A
  helper only laws call (directly or through other such helpers), and the checked-arithmetic or `to_i` runtime only
  laws use, is still compiled into release but marked so `-Dwarnings` does not refuse it as dead code.

Refused: a `forall:` group that does not exist, a parameter that is not one of its fields, an example law with
parameters, `cases:` without `forall:`, a duplicate name, a body that does not end in a bool, a law that calls an
async helper (a law's body runs synchronously), and a field a law cannot generate exactly (`:upload`, nested objects
and maps, `multiple_of:`, `format:`, and an exclusive bound on an `:f64`).

The law machinery is the `r2r-laws` gem (`../r2r-laws`: `Laws::Domain`, `Laws::Decl`, `Laws::Proptest`), shared with clap_dsl
and gpui_dsl and kept dialect-neutral by its own `test/test_laws_layering.rb`.

## Route laws

A law may send the service requests with `respond`:

```ruby
law :sum_route_adds, forall: :Pair, cases: 64 do |a, b|
  r = respond(:get, "/sum?a=#{a}&b=#{b}")
  r.status == 200 && r.body == (a + b).to_s
end
```

`respond(method, path, body: "a=1&b=2", headers: { "Cookie" => c })` answers in-process: the router `main` serves,
called through tower's `oneshot` with peer address 127.0.0.1, after the same startup `main` runs (settings, cookie
keys, files, the database), once per test binary. A body is sent as a form unless `headers:` names a content type.
The answer is a `Law::Response` record with `status`, `body`, `location`, `content_type` and `headers` (one
"name: value" line per header, names lowercase). Only a law may call it.

`cookie_header(:session_token, token)` is the `name=value` a browser sends back after the service's
`set_cookie :session_token, token`, signed the same way (the cookie's format, `format:`, or `signed: false`), so a
law can make signed-in requests: `respond(:get, "/account/bots", headers: { "Cookie" => cookie_header(:session_token,
"law-member-token") })`.

The state is the service's own: a database law runs against the database the environment names, shared by every law
in the run, so point it at a disposable copy. A crate with a route law splits `main` into `axum_dsl_start()` and
`axum_dsl_app()` (unchanged otherwise) and adds `tower` as a dev-dependency.

## Query laws

A law body may call a `query` (never an `execute`) and compare results with `==`. The statement runs on the
service's own database, after the same startup `respond` waits for, once per test binary (so the crate is split into
`axum_dsl_start()`/`axum_dsl_app()` as for a route law). This is how to port a hand-written statement to a relation
and prove the port: keep the old statement beside the new one and assert that both return the same records, in the
same order, for generated arguments (`examples/query_laws.axum.rb`).

```ruby
query :recent_notes_sql, args: { limit: :i64 }, returns: list(:Note), sql: "SELECT id, body, created_at, tag FROM notes ORDER BY id DESC LIMIT :limit"

model :Memo, table: :notes do
  query :recent_notes, args: { limit: :i64 }, returns: list(:Note) do
    order(id: :desc).limit(arg(:limit))
  end
end

law :recent_notes_match_their_sql, forall: :Page, cases: 32 do |limit|
  recent_notes_sql(limit: limit) == recent_notes(limit: limit)
end
```

- `==` and `!=` compare two results of the same type: a record, a list of records (element by element, in order), a
  nil-able record or scalar, or a scalar. The records derive `PartialEq` when a law compares them, so a field that
  differs fails the law.
- Point the database at a disposable copy (schema and seed), as for route laws: every law in the run shares it. A
  query only a law calls is compiled into release but marked so `-Dwarnings` does not refuse it as dead code; delete
  the old statement and the law once the port holds.
- Refused: an `execute` (a law writes nothing: its cases would pile writes onto the one shared database), and a
  query called in a helper (a law's own body is the place for it).
