# The body language

The Ruby subset a route body may use, and the helpers it can call.

_See also: [README](../README.md), [Views](views.md)._

## What a route body may contain

Ordinary Ruby from a deliberately small subset. Anything else is a compile error that says what to use
instead. `axum_dsl skill` writes the complete, generated reference; the outline:

- **Reading the inputs.** A route body takes no block parameters; it reads the fields its `params:` group
  declared with `params[:field]` (a symbol, or the same name as a string), at the declared type. An
  `optional: true` field is nil-able (see below). A route that names `params:` also reads
  `errors[:field]`: the message the generated `check()` has for that field, and an empty string when the
  request passed it (or that field had no violation), so a page interpolates it with no conditional. A
  request that breaks several constraints fills one entry per field, where `check()` itself reports only
  the first, so a body that renders one field still gets what it asked for. It carries only the
  `check()`'s own violations, so a request axum's extractor rejects — a missing field, a value that is
  not the field's type — never reaches the body: that is axum's own 422, the same split the form body has
  (see [Coverage](coverage.md)). A body that reads `errors` runs on a violation, and its response keeps
  the 400 the violation always answered with, unless the body sets `status(...)`, which decides for
  itself. A route that never reads it is answered 400 before its body runs, exactly as before. `errors`
  in a route with no `params:`, or in one whose group declares no constraint for the check() to report,
  is refused.
- **Syntax:** literals, locals (`name = expr`, no reassignment; a name must be snake_case and not a Rust
  keyword), arithmetic and comparisons, `&& || !`, `if`/`elsif`/`else`, `unless`, ternary,
  `case`/`when` (with string, integer and regex subjects), string interpolation, guard clauses
  (`return "x" if cond`, `raise "msg" unless cond`), and blocks with one parameter.
- **Statements before the last expression:** only `name = expr`, a guard clause, `status(...)`,
  `content_type(...)`, `headers(...)`, `etag(...)`, a bare `execute`/`query` call (its value dropped) or `.each { ... }`.
  The last expression is the response.
- **Transactions.** With a `database`, `transaction do ... end` runs declared statement calls on one
  connection and is the block's value: `name = query/execute call` locals, bare calls, and a final call or
  local. A database error rolls the block back. A nested `transaction`, `return`, `raise`, guard clause or
  non-SQL statement inside is refused: a `return` would bypass the rollback, and non-SQL work does not belong
  in a retried/rolled-back unit. In Rust the block is a `move` closure, so a value it uses is moved into it;
  clone it or compute it outside if the route needs it afterwards.
- **Strings:** `upcase downcase strip capitalize length split partition chars lines reverse tr delete
  squeeze index start_with? end_with? include? empty? match? =~ gsub sub to_i`, slicing `s[start, len]`
  and `s[i]`, `s * n`, and `Integer(text, 10)`. `gsub`/`sub` take a string or regex literal, or a block;
  `=~` takes a regex literal and gives the character index of the first match (nil when none). A string
  literal is a borrowed `str`: `s + "x"` concatenates, but `"x" + s` is refused; use interpolation or
  `.to_s` when the literal comes first.
- **Lists:** `split`, `chars`, `lines`, `n.times`, `a.upto(b)`/`a.downto(b)`, ranges `(a..b)`, array
  literals, and `map select reject find any? all? count sort uniq reverse first last [] join include? empty?
  partition to_a`; `sum`, `min` and `max` are for integer and float lists; `each` runs its block for side
  effects and returns the list. Blocks
  may use arithmetic, `to_i`, `raise` and `return`. A `list(:Address)` supports `length size empty? first
  last [] each map select reject find any? all? count reverse`; ordering, equality and stringification
  (`sort`, `uniq`, `include?`, `join`, `sum`, `min`, `max`) are refused, because an object has none.
- **Maps.** A typed map is read-only. `m["k"]` is nil-able, and `fetch key? has_key? member? keys values
  size length empty? merge` read it; `map`, `select`, `reject` and `each` take a `|k, v|` block (the
  String key and the value). `to_json` writes a map as a JSON string through `serde_json`, a dependency of every emitted crate;
  no example or test exercises it yet (see [Coverage](coverage.md)).
- **Nil-able values.** Methods that return nil in Ruby (`first`, `last`, `xs[i]`, `index`, `=~`, optional
  fields) must be used through `|| default`, `|| raise("msg")`, `.nil?` (which narrows, below) or `.to_s`, so a missing value is
  never silently used. `||` is for nil-able values only: on a required one it is refused, so a required
  list takes no `|| []` fallback. An optional nested object is read with `&.` (`address&.city`). After `.nil?` a local is
  non-nil where the test says so: the `else` of `if x.nil?` (or the body of `if !x.nil?` / `unless x.nil?`), the
  other arm of `x.nil? ? a : b`, and the rest of the body after a guard such as `return halt(404) if x.nil?`
  or `raise "msg" if x.nil?`. Only a plain local narrows, and only a bare `.nil?` test, with one exception:
  `x.nil?` as the **left** operand of `||`. In `x.nil? || rest`, `rest` sees x non-nil (`user.nil? || !Bcrypt.verify(p, user.password_digest)`),
  and a guard `return halt(401) if x.nil? || rest` (or `raise ... if`) narrows x for the statements after it, like the
  plain guard; `unless x.nil? || rest` proves nothing, and `!x.nil? || rest` and `&&` do not narrow. The compiled test is a
  `match` whose `Some` arm binds x, so there is no unwrap and nothing that can panic. Nothing more general than that shape narrows.

  ```ruby
  note = find_note(id: params[:id])
  if note.nil?
    halt(404, "no such note")
  else
    json(note)
  end
  ```
- **Integers follow Ruby:** `/` rounds down and `%` takes the sign of the divisor. `Rust::Int32(a) / b`
  opts into Rust's truncating behaviour. Arithmetic is overflow-checked and a result that does not fit
  comes back as an error that says what, where and how to fix.
- **Strings follow Ruby:** `strip` is not Rust's `trim`. `Rust::Str(s)` opts into Rust's `str` behaviour:
  `trim`, `strip` (the same as `trim`, with notice `N-STR-STRIP-RUST`), `to_lowercase`, `to_uppercase`,
  `len` (bytes), `lines`, `split(pat)`, `contains(pat)`, `starts_with?(pat)` and `replace(from, to)`;
  `to_s` leaves it for a plain string, which a body must do before returning it.
- **Response helpers.** `text(s)`, `html(s)`, `json(value)`, `redirect(path)`, `halt(status, body)` and
  `render(name, locals: {...})` are values, and the body's last expression is the response; a render
  answers with a view, a `.html` file the compiler reads and compiles into the Rust (see [Views](views.md)).
  `redirect` answers 302 by default and takes `status:` (301, 302, 303, 307, 308); `text`, `html`, `json`
  and `render` take `status:` (an integer literal, such as `status: 401`) and `content_type:` (a string
  literal MIME type, such as `content_type: "text/vnd.turbo-stream.html"`), which travel on the value as
  its status and Content-Type header, so a `return` can carry them. A `redirect` path is written in the
  source: a string literal, or a literal
  interpolating only numbers and bools (`redirect("/rooms/#{room_id}")`). It becomes the `Location`
  header, and a computed string could carry a byte the header rejects, so it is refused. Its literal text
  is visible ASCII (0x20-0x7E, or a tab), with no leading or trailing whitespace, because that text is the
  header value. A body may not use both `status(code)` and a helper's `status:`: the statement applies
  to the final response and the helper's status belongs to the value it returns, so the two together are
  refused. Nor may it use both `content_type(:name)` (the default for the routes that follow) and a
  helper's `content_type:` (on that value). `status(code)`,
  `content_type(:name)` and `headers "Cache-Control" => "no-store"` are statements, not values: `headers`
  puts header lines on the response this body produces, or, in a `before` filter that passes the request
  on, on the response that follows it. `etag(value)` is a route statement beside them: `value` is a string
  computed at run time (a helper, an interpolation, a query field), the response carries `ETag: value`, and
  a request whose `If-None-Match` lists the value (comma-separated, compared after trimming) is answered
  304 with no body and the ETag still set. Only a strong, exact tag matches today: `If-None-Match: *` and a
  weak `W/"v1"` are not matched, and a non-GET request with a matching tag still answers 304 rather than
  412. `headers` stays literal; `etag` is the computed header, and a body sets it once. A body that ends in
  a plain string is a 200 text response.
- **Escaping.** `h(value)` escapes `&`, `<`, `>`, `"` and `'` and gives a string: it is what a page
  interpolates, inside `html(...)` or a string. `raw(value)` is the same value with no escaping, and is
  the XSS door, named so a review can grep for `raw(`; a view's `{{ name }}` and `{{ name|raw }}` are exactly
  these two functions (see [Views](views.md)). Escaping is by value, not by context: a
  `javascript:` URL in an `href` survives `h`, and nothing is sanitised (see [Coverage](coverage.md)).
- **Errors.** `raise "msg"` and integer overflow end the request with an error: the `error` filter
  answers it, or the generated service answers a plain 500. `return value` ends it with that string, even
  from inside a list block. There is no `begin`/`rescue`: failures are values, so a retry is written as
  data (`a = attempt(x); b = if a == "" then attempt(y) else "" end`) rather than control flow.
- **Settings, files and bindings.** `setting(:name)` reads a value the service declared with a top-level
  `setting :name, env: "..."`, resolved once when the server starts; a route or filter body may read it, a
  helper or a binding body may not (see [Coverage](coverage.md)). `file_text(:name)`
  is the text of a file declared with `file "path", as: :name`, read from disk on each call (an error if
  it cannot be read); `file_path(:name)` is the path it is read from. `entry(:name, :fn)` is the string
  `"fn"`, refused unless `:fn` is in the file's `entries:`; `entry_args(:name, :fn, key: value, ...)`
  builds the arguments as JSON text through `serde_json`, a dependency of every emitted crate; no example
  or test exercises it yet (see [Coverage](coverage.md)).
  `rust(:name, args)` calls a declared `rust_fn`/`cmd_fn`/`script_fn`, and `Module.method(args)` calls a
  binding loaded with `use_bindings`.

The DSL is strict on purpose so the file says exactly what the service does and the generated Rust stays
warning-free. Unused locals, declarations, helpers and params are all compile errors. Regex literals are
translated to Rust's `regex` crate; features the engines disagree on (lookaround, backreferences, `\h`,
`\Z`, possessive quantifiers) are rejected. Regex literals are only accepted by `gsub`, `sub`, `match?`,
`=~` and `when`.

`make probe` runs about fifty one-line bodies through the compiler and prints which Ruby it accepts today.

## Helpers

Logic that more than one route needs goes in a helper, with its types written out:

```ruby
helper :checked_id, args: [:string], returns: :i64 do |raw|
  raise "not a number: #{raw}" unless raw.match?(/\A\d+\z/)
  raw.to_i
end

params :UserParams do
  field :id, :string, in: :path
end

get "/users/:id", params: :UserParams do
  text(checked_id(params[:id]).to_s)
end
```

Types are `:string :i32 :i64 :f64 :bool :string_list :i64_list :f64_list`, and a trailing `?` makes an
argument or a result nil-able (`:string?`, `:i64_list?`, ...). A helper may also take keyword parameters,
declared with `kw: { limit: [:i32, false] }` and a literal default in the block
(`do |text, limit: 0| ... end`), called by name in any order (`h(text, limit: 3)`) or omitted for the
default. A helper can only call helpers declared above it, so recursion cannot happen. A helper whose body cannot fail compiles to a plain
function; one that can (a `raise`, checked arithmetic, `to_i`, or a helper that can fail) returns a
`Result`, and its call site propagates the failure to the request's error. A helper that nothing calls is an error. Sorbet cannot know names declared in the
DSL, so `axum_dsl rbi FILE...` writes their signatures to `sorbet/rbi/axum_dsl/dsl_helpers.rbi`
(`make rbi-helpers`; `make rbi-helpers-check` fails if it is stale) and files that call helpers stay
`# typed: true`. Two files declaring one helper with different types are refused. The compiler checks
every call regardless. `setting(:x)` works in a route or a filter body but not in a helper, so a helper that needs one takes
it as an argument.

## Not supported yet

These are refused today; the compiler's message is the authority if this list is out of date.

- `def` inside a body, and `while`/`for` loops.
- Regex literals anywhere other than `gsub`, `sub`, `match?`, `=~` and `when`.
- The content-block builders (`image`, `audio`, `resource_link`, `embedded_text`, `embedded_blob`) are
  refused: an axum service answers with `text(...)`, `json(...)` or `html(...)` and has no content blocks.
- A path capture (`in: :path`) must be a scalar; a list or a map there is refused.
- A map value may be a scalar, a list, another params object or one nested map; deeper nesting is
  refused.
