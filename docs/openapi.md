# OpenAPI

An API document the compiler writes from the routes, and the service serves.

_See also: [The DSL](dsl.md), [Examples](examples.md), [Notifications](notifications.md)._

## One declaration

```ruby
server "notes", version: "1.2.0"
openapi "/openapi.json"                       # or: openapi "/api.json", title: "Notes API", version: "2"
```

`openapi "/openapi.json"` makes the service answer `GET /openapi.json` with an OpenAPI 3.1 document of its routes,
as `application/json`. `title:` and `version:` name the API and default to the server's name and version. Without
the declaration nothing changes: no document, no extra route, and a route's or a field's `description:` stays in
the IR only.

This is the opposite direction from rmcp_dsl's `openapi "spec.json"`, which *reads* a document to make tools.
Here the DSL is the source and the document is the output.

The compiler builds the document while it compiles (`lib/axum_dsl/openapi.rb`) and writes it into the emitted
crate as one string constant. The running service does no work to answer the request, and the crate has no
OpenAPI dependency, so builds are no slower. The text is compact JSON with a fixed key order (paths in
declaration order, component schemas sorted by name), so the same DSL gives the same bytes and a golden pins it.

## What the document says

Every route is one operation, keyed by its path (`:id` is written `{id}`) and verb. Its `operationId` is the verb
and the words of the path (`get_notes_id`; a clash gets a numeric suffix).

| DSL | Document |
|-----|----------|
| route `description:` | the operation's `description`, and its first line as the `summary` |
| a field `in: :path` or `in: :query` | an entry of `parameters` (`required` for a path field and for a query field that is neither `optional:` nor has a `default:`) |
| fields `in: :body` | `requestBody` with `application/json` |
| fields `in: :form` | `requestBody` with `application/x-www-form-urlencoded` |
| field `description:` | the parameter's or property's `description` |
| `min:` `max:` `exclusive_min:` `exclusive_max:` `multiple_of:` | `minimum` `maximum` `exclusiveMinimum` `exclusiveMaximum` `multipleOf` |
| `min_length:` `max_length:` `pattern:` `format:` `enum:` | `minLength` `maxLength` `pattern` `format` `enum` |
| `min_items:` `max_items:` | `minItems` `maxItems` (`minProperties` `maxProperties` on a `map(...)`) |
| `default:` | `default`; the field is not `required` |
| `optional: true` | left out of `required` |
| `:i32` `:i64` `:f64` `:bool` `:string` | `integer` (`int32`/`int64`), `number` (`double`), `boolean`, `string` |
| `:string_list` `:i64_list` `:f64_list` | an `array` of those |
| `map(:i64)`, `map(map(:i64))` | an `object` with `additionalProperties` |
| another params group, `list(:Name)`, `map(:Name)` | a `$ref` to `components/schemas/Name` |
| a type a binding owns | `{}`, any JSON value: the compiler does not know its shape |

`pattern:` is Ruby (Onigmo) source, carried over as written; it is the JSON Schema `pattern` as long as it uses
syntax both share (`^`, `$`, classes, counted repeats), which is also what the Rust `regex` crate accepts.

## Responses are minimal

The DSL does not declare what a body answers, so the document does not guess. Each operation lists:

- `200`, with no schema;
- `400` when the route has a path, query or JSON body field, or its params carry a constraint the generated
  `check()` enforces (the body of that answer is the compiler's message, as text);
- `422` when the route has a JSON body or a form, for axum's `Json` and `Form` extractors rejecting a body that
  lacks a field or has one of the wrong type.

A route with no fields lists `200` only. A `not_found` or `error` filter, a `before` filter that halts, and a
body that answers another status are not described.

## Refused

- a second `openapi`;
- a path with a `:name` capture, a `*splat` or a regex character (it is written out, like a `serve_file`'s);
- a path that a `get` or `head` route, a `serve_file` or a `static` mount already answers, since axum would panic
  when it builds the router;
- an empty `title:` or `version:`.

## Notifications

`N-OPENAPI` (a notice) names the path and how many operations the document describes. `W-OPENAPI-AUTH`, which the
code table once reserved, is retired: the DSL has no authentication concept to warn about, and the document
declares no security schemes.

## Example

`examples/validate.axum.rb` declares `openapi "/openapi.json"`. `test/e2e_validate.sh` fetches it, parses it as
JSON and checks the paths, `age`'s `minimum`/`maximum`, a route description, the form request body and the `400`
and `422` responses; `test/test_openapi.rb` covers every row of the table above without cargo.
