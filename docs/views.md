# Views

Pages the server renders: a `.html` file the compiler reads, the ten markers it may hold, and where a
client framework's template ends and a static asset begins.

_See also: [The DSL](dsl.md), [The body language](body-language.md), [Coverage](coverage.md)._

## A view is a file, read at compile time

`render :signup` answers with `views/signup.html` — the folder `set :views` names, `views` when it names none —
resolved beside the server file being built, even when the `render` is in a `use_dsl` fragment, on the same path rule a
declared asset uses: a relative path, without a leading `/` and without `..`. The file is read when the compiler
runs and its text is compiled into the emitted Rust, so the crate carries no template, no template engine and no
`.html` file at all: the build needs the view, the running service does not. That is the difference from
`static`, whose file is copied into the crate for the running service to serve.

An earlier build resolved a fragment's views beside that fragment. A split written for that rule must now
move its `views/` folder beside the server file, or point `set :views` at the folder there: `set :views` is
one server setting, and the view rule does not change with the file a `render` is written in.

Every view the compiler read is an input of the compile, like a binding or a `rust_file`: `--print-inputs`
names it, and the language server compiles the editor's buffer in place of the file on disk, as it does for every
other input.

`render` is a response helper beside `text`, `html`, `json`, `redirect` and `halt`, so it is the last expression
of a route or a filter body (or a branch of one):

```ruby
get "/signup" do
  render :signup, locals: { title: "Sign up", name: "", email: "", error: "" }
end
```

The name is a symbol (`:signup`) or a string (`"signup"`), and `locals:` and `layout:` are the only keywords. A
page is HTML, so a render answers through axum's `Html`, with `content-type: text/html`.

### Layouts

`set :layout, :app` gives every render in the file that layout; `render :x, layout: :other` names another for one
render, and `layout: nil` opts out of the default for one render. The layout is a view like any other, and
`{{ yield }}` is where it writes the markup of the view it wraps:

```html
<!doctype html>
<html lang="en">
<head><title>{{ title }}</title></head>
<body>
<main>{{ yield }}</main>
</body>
</html>
```

A view rendered directly (no layout) may not write `{{ yield }}`: it has no child. A layout that never writes
`{{ yield }}` is refused as well, because it would silently drop the view it wraps. `set :layout` is read and
checked when it is declared, so a setting that names a view which is not there, is not `.html`, or writes no
`{{ yield }}` is refused at the setting rather than at every render that inherits it.

## The ten markers

| Marker | Is |
|--------|-----|
| `{{ name }}` | the local `name`, escaped for HTML: the same bytes `h(name)` produces |
| `{{ name\|raw }}` | the local `name` with no escaping: the same bytes `raw(name)` produces |
| `{{ name\|sanitize }}` | the local `name` run through the compiler's HTML sanitiser (ammonia, default allowlist plus generic `class`), not escaped: for an Action Text body already holding markup |
| `{{ yield }}` | the wrapped view's markup, already built and never re-escaped; legal only in a layout |
| `{{ csrf_token }}` | the CSRF token `use_layer :csrf` put on the request, for a form's hidden `authenticity_token` |
| `{{ asset_path "campfire.css" }}` | the fingerprinted URL of a file under a `static ... digest: true` mount |
| `{% raw %}…{% endraw %}` | the text between the two directives, copied byte for byte |
| `{{ partial :name, key: value }}` | another view file, read at compile time and inlined here (see [Partials](#partials)) |
| `{% for x in xs %}…{% endfor %}` | the text between the two directives, once for each element of the list `xs` (see [Loops](#loops)) |
| `{% if name %}…{% else %}…{% endif %}` | one of two branches, chosen by the bool or nil-able `name`; `{% else %}` is optional (see [Conditionals](#conditionals)) |

`|raw` and `|sanitize` are filters on the first marker, not separate directives. Whitespace inside a marker is optional
(`{{name}}` is `{{ name }}`), and there are no other forms: no expressions
(`{{ a + b }}` is refused), no filters beyond `|raw` and `|sanitize` (`{{ name|upcase }}` is refused), no comparisons, no
negation and no `{% elsif %}`. **The logic lives in the route body**; a view says only where the values go. That
is deliberate: a view that could compute would be a second language to learn, to type-check and to keep in step
with the body language, which already has the blocks, the conditionals and the helpers. Three forms grew the
grammar: `partial`, only as far as an attribute list (a name and flat `key: value` arguments), `{% for %}`, only
as far as one list and one new name, because a page that lists database rows would otherwise build its HTML in
the route body, and `{% if %}`, only as far as one name and one optional `else`, because a page that shows a
flash, a badge or a button only sometimes would otherwise build that markup in the route body. Conditionals are
in as far as one name and an optional `else`; expressions and comparisons are still out, and the rest of the
boundary below still holds.

Nothing outside a marker is interpreted at all, so `{{` is literal everywhere except at the start of a marker —
and inside `{% raw %}`, where it is not a marker either. That is why `{% raw %}` is also how a literal `{{` is
written, and why a `{%` inside a raw region that is not `endraw` is text like any other: one client framework's
syntax may hold another's.

## Fingerprinted assets

`static "/assets", dir: "public", digest: true` copies each file under a content-hash name and serves only
that name: `campfire.css` becomes `/assets/campfire-3f9a0c1b2d4e.css`, where the twelve hex digits are the
first twelve of the file's SHA-256, computed when the compiler runs from the bytes it copied. Because the
name changes whenever the bytes do, that URL is safe to configure a far-future `Cache-Control` for. The
undigested name is not copied, so it is a 404 rather than a stale second URL.

A view names one with `{{ asset_path "campfire.css" }}`: the quoted path is relative to the digest mount's
directory (no leading `/`, no `..`), and the marker writes the mount prefix and the fingerprinted name. It
is resolved at compile time and is not a local, so `locals:` never names it. With one digest mount the
resolution is unambiguous; a file no mount copied, a missing digest mount, and two digest mounts are each
refused at the render with the view's file and line. `digest:` off (the default) copies and serves the
paths it always did, byte for byte. The mount must be declared before the route or view that names it: a
render is compiled where it appears, so `asset_path` cannot see a `static ... digest: true` written later
in the file. The generated `ServeDir` sends no `Cache-Control` of its own; the digest only makes a
far-future header safe, so set that header in front of the service; a `static` mount has no header
option of its own.


`examples/assets.axum.rb` is the worked example: `static "/assets", dir: "fingerprints", digest: true` and
`{{ asset_path "campfire.css" }}` in `asset_views/fingerprints.html`. `test/e2e_assets.sh` fetches the URL
the page names and compares the bytes, and `test/test_assets.rb` pins the emitted names and the refusals.

## Partials


`{{ partial :form_field, label: "Name", value: name, error: name_error }}` inlines another `.html` file from the
same folder a `render` reads (`set :views`, default `views`): `:form_field` is `views/form_field.html`. The file is read
at compile time, for the same reason a view is, and its markup is spliced into the caller's — no function, no
template engine and no `.html` file reaches the crate. A partial is legal in a view and in a layout.

The call's arguments are a flat `key: value` list, and a value is a **literal** (a string, an integer or
`true`/`false`) or a **bare name** — no expression, no filter, no nesting:

```html
{{ partial :form_field, label: "Email", field: "email", value: email, error: "" }}
```

A partial is a second scope, and there is one rule for each:

- An argument's **value** resolves in the caller's scope. A bare name is one of the caller's own locals — the
  same local a marker in the caller would read — and a literal is itself.
- The partial's own markers resolve **only** against its arguments. `form_field.html` may write `{{ label }}` and
  `{{ value }}`, and those are the values the call passed; it cannot reach any other local of the caller, so
  the same partial renders the same way wherever it is called from.

The arguments passed must be **exactly** the names the partial's markers read, refused in both directions with
the name: an argument no marker reads, and a marker no argument feeds. That is a rule of the call, separate
from the render's own `locals:` rule below, which is the names the view's, the layout's and the partial calls'
markers read. A partial is not a layout, so it has no `{{ yield }}`; one that writes it is refused.

A partial may declare its arguments once with `{% args %}`, a Ruby keyword-parameter list (parsed as
`def _(label:, hint: "")`): `label:` is required, `hint: ""` has a default, and a default is a string, an integer
(negative too) or `true`/`false`. It writes no output, and only a partial may have it (a view rendered with `render`
or a layout is refused), once per file. The declared names must be exactly the names the markers read; a call
must pass every required name, may omit a defaulted one (the default is used) and may not pass an undeclared one.
A partial without `{% args %}` takes exactly what its markers read, as above.

```html
{% args label:, hint: "" %}
<label>{{ label }}</label><small>{{ hint }}</small>
```

This mirrors Askama's `{% macro field(label, hint = "") %}`.

A partial that reaches itself, directly or through a chain of partials, is refused as a cycle rather than
expanded, because a partial is inlined into its caller and the recursion would never finish.

There is no `{% include %}`, no named block, no slot and no template inheritance beyond the single
`{{ yield }}`: a partial is one file spliced in, and that is the whole of it.

## Loops

```html
<ul>
{% for note in notes %}
  <li id="note-{{ note.id }}">{{ note.body }} <small>{{ note.created_at }}</small></li>
{% endfor %}
</ul>
```

`{% for x in name %}` … `{% endfor %}` repeats its text for each element of the list local `name` — it mirrors
Askama's `{% for x in xs %}`. It is the smallest loop: no expressions, no filters beyond `|raw`.

- `name` is a local the render passes (`locals: { notes: recent_notes(limit: 20) }`), a list of strings, integers
  or floats, of a query's records, or of a params object (`list(:Address)`). The list is a read: `locals:` must
  pass it, as for any marker. A loop over a field of an enclosing loop variable is written
  `{% for tag in note.tags %}` (the field must be a list); any other expression is refused.
- `x` is a new snake_case name. It is not a local, so `locals:` never lists it, and it may not shadow a local
  or the variable of an enclosing loop. It exists only between `{% for %}` and `{% endfor %}`.
- Inside, `{{ x }}` writes an element of a list of strings or integers, and `{{ x.field }}` writes a field of a
  record or params object — exactly one dot, and the field must exist (the refusal lists the fields, as body
  field access does). `|raw` works on both. A field that is `optional: true` is refused in a marker: a marker
  never writes a nil, so the body supplies a value for it before the list reaches the view.
- Loops nest, and they work in a layout and in a partial. A partial that loops declares the list in its
  `{% args %}` like any name it reads (`{% args items: %}`); the loop variable is not an argument. Inside a loop a
  partial argument may be `x` or `x.field`. `{{ yield }}` and `{% args %}` cannot sit inside a loop, and a
  `{% raw %}` region inside one stays byte for byte.
- An unclosed `{% for %}`, an `{% endfor %}` without a `{% for %}`, a loop variable used outside its loop and a
  loop over a local that is not a list are refused with the view's file and line.

The loop compiles to a block that builds a `String` — `for x in &list { s.push_str(&format!(…)); }` — spliced
into the page's `format!` as one argument, with the same `axum_dsl_html_escape` the plain markers use.

## Conditionals

```html
{% if flash %}
  <p class="flash">{{ flash }}</p>
{% else %}
  <p class="quiet">Nothing to report.</p>
{% endif %}
```

`{% if name %}` … `{% else %}` … `{% endif %}` writes one of two branches. `{% else %}` is optional; the
`{% endif %}` is not. `name` is a bool or nil-able local, or a bool or nil-able field of an enclosing loop
variable, and the branch is chosen by Ruby truthiness: `nil` and `false` are false, everything else (including
`""` and `[]`) is true, and a nil-able bool is true only for `Some(true)`.

- Inside the taken branch a nil-able `name` reads as its value: `{{ name }}`, `{% for x in name %}` and a
  partial argument see the non-nil value there; outside the branch it stays nil-able, so a marker of it outside
  is refused as before. The guard is an `if let`, never an `unwrap`.
- A nil-able field of a loop variable narrows the same way, under the name the marker spells (`{{ task.note }}`).
- Conditionals nest, and they work inside and around `{% for %}`, in a layout and in a partial. They add no
  marker: both branches' names are still part of the render's `locals:`, as the condition's own name is.
- There is no `{% elsif %}`, no comparison and no negation: a condition is one name, and a route that must
  combine tests decides in the body and passes the result.

The conditional compiles to a block that builds a `String`, spliced into the page's `format!` as one argument:
`{ let mut __s = String::new(); if name { __s.push_str(&format!(…)); } else { … } __s }`, with an `if let
Some(__if_name) = name` guard where the name is nil-able.

## Locals

`locals:` names the values the markers read, and its keys must be **exactly** the union of the view's and its
layout's marker names, minus `yield`; a `{{ partial }}` contributes the caller's locals its argument
values name:

```ruby
render :signup, locals: { title: "Sign up", name: params[:name], email: params[:email], error: errors[:name] }
```

Both directions are refused, and the refusal names the local — a marker no local feeds (`views/signup.html:3:
{{ name }} reads a local, so the render must pass it: locals: { name: ... }`) and a local no marker reads
(`subtitle is passed to this render but no marker reads it`). A view with no markers takes no locals, and an
unknown keyword, a duplicate local or a `locals:` that is not a hash is refused too. `yield` is not a local: it
is the layout's child output. `{{ csrf_token }}` and `{{ asset_path "..." }}` are not locals either, so
`locals:` never names them.

A local's value is any value the body language allows and a marker can write — a string, a number or true/false,
the same values `h(...)` and an interpolation take. A secret, a nil-able value or a map is refused where the
marker reads it, and so is a list, unless the view loops over it (`{% for %}`); the refusal carries the value's
own position in the DSL file.

The refusal is reported at the declaration that named the view (the position an editor can show, and the one
`test/refusals/` pins), and the view's own file and line travel inside the message.

## Escaping

`{{ name }}` is exactly `h(name)`, and `{{ name|raw }}` is exactly `raw(name)`: the two spellings share one
implementation, so a page and a body cannot escape differently. `{{ yield }}` is already-built markup and is
never re-escaped, so a page's markup cannot be double-escaped by its layout.

Escaping is by value, not by context, exactly as it is in the body language: a `javascript:` URL in an `href`
survives both `h` and `{{ }}`, which escape and sanitise nothing (see [Coverage](coverage.md)).
`{{ name|sanitize }}` is the named door for a value that is already HTML — an Action Text body — and cleans it
with ammonia's default allowlist (its tags, its attributes and its URL schemes, with generic `class` allowed
for Trix); the compiler emits the helper and the `ammonia` dependency only into a crate whose views use it. A
value written with `|raw` is the route's own responsibility: a route that puts request data into a `|raw` value
without escaping it first hands the browser a tag of the visitor's choosing. `{{ name }}` and `h(name)` stay
exactly each other; the sanitiser does not replace them, and a value that is not a string is refused where
`|sanitize` reads it. `examples/views.axum.rb` shows the shape that is right: the route escapes each value with
`h(...)` as it builds the fragment, and the page writes that fragment as markup.

## The boundary: a view is a page the *server* renders

A view is compiled, so the `{{ }}` in it belongs to the server. A page whose `{{ }}` belongs to a **client
framework** (Vue, Handlebars, a `<template>` an SPA clones) is not a view: the browser evaluates the user data
inside a live client template, and HTML escaping does not prevent that, because the escaping would have happened
before the framework saw the string. Such a page is a **static asset** — `static "/app", dir: "spa"` — or a
`file` a body reads if the server must build it.

`{% raw %}` is for the region of a server-rendered page that a client framework owns: the markers inside it are
copied byte for byte, so the framework receives its template exactly as written and never a rendered value.
`examples/views/layout.html` carries one — a `<script type="text/x-template">` holding two live `{{ }}` values,
neither of which the compiler evaluates.

## Refusals

Each of these is refused by name and pinned by a fixture under `test/refusals/`:

- a marker naming a local the render does not pass, and a local no marker reads;
- an unknown directive (`{% unless x %}`), a marker that is not one of the ten forms, and a filter other than
  `|raw` or `|sanitize`;
- `|sanitize` on a number, bool, list or record: the sanitiser takes HTML text;
- a `{% for %}` that is never closed, an `{% endfor %}` with no `{% for %}`, a loop variable used outside its loop,
  a loop variable that shadows a local or an enclosing loop variable, a loop over a local that is not a list, a
  field a record does not have, a nil-able field, and a record written whole where a field is wanted;
- an `{% if %}` that is never closed, an `{% endif %}` or `{% else %}` with no `{% if %}`, a second `{% else %}`,
  an `{% elsif %}`, a condition that is an expression or a negation, and a condition that is not a bool or a
  nil-able value;
- `{% raw %}` with no `{% endraw %}`, and `{% endraw %}` with no `{% raw %}`;
- `{{ yield }}` in a view rendered with no layout, and a layout that writes no `{{ yield }}`;
- a `render` naming a view that is not there, and a name whose extension is not `.html` — the escaping context
  is inferred from the extension, as Askama does, so a `.erb`, `.vue` or `.md` file is not a view and is refused
  rather than read as HTML;
- a partial call whose arguments are not exactly the names the partial's markers read — an argument the partial
  does not use, and a marker no argument feeds — a duplicated or a malformed argument name, a `{{ partial }}`
  with no name or an argument value that is not a literal or a bare name, a partial file that is not there, a
  partial that writes `{{ yield }}`, and a partial that reaches itself (a cycle);
- a `set :views` or `set :layout` whose value is not a name a view can have;
- a `{{ csrf_token }}` with no `use_layer :csrf`, a marker that takes a filter (`{{ csrf_token|raw }}`), and a
  `{{ csrf_token }}` in a filter that runs without a request;
- an `{{ asset_path "..." }}` with no digest mount, naming a file the mount did not copy, with more than one
  digest mount, or with a path that is not a relative double-quoted string.

## The example

`examples/views.axum.rb` exercises the whole surface: a signup form whose GET renders it, whose good POST
renders a thanks page inside the layout and whose bad POST re-renders the form with `errors[:name]`; the form's
two fields come from `views/form_field.html` through `{{ partial :form_field, ... }}`, with different arguments per call;
a `{% raw %}` block and one `|raw` use; `layout: nil` and a second layout (`layout: :plain`). `make e2e-views`
builds it and `test/e2e_views.sh` drives it over HTTP: the form, the partial's two fields, the re-rendered form
with the check's message, the escaped name, the raw region byte for byte, the `|raw` fragment as markup, the
conditional markup present in one request and absent in the other, the sanitised Action Text body whose
`<script>` and `javascript:` `href` are gone, and the absence of a `views/` directory in the emitted crate.
