# Notifications

_See also: [README](../README.md)._

Where Ruby and Rust behave differently, or the compiler cannot see the code, it prints a notification. They
never change the generated code and never fail the build.

| Code | Meaning |
|------|---------|
| `N-STR-STRIP-RUBY` | `strip` keeps Ruby's rules (NUL and ASCII whitespace), spelled out in Rust |
| `N-STR-STRIP-RUST` | `Rust::Str#strip` uses Rust `trim()` (Unicode whitespace, including NBSP; NUL is not stripped) |
| `W-STR-CAPITALIZE` | Ruby titlecases some characters (for example `ß`); Rust only uppercases |
| `N-RUST-INJECTED` | a `rust_item` or `rust_file` was injected; the compiler does not check its Rust |
| `N-EXEC-INJECTED` | a subprocess runs on every call; no sandbox |
| `N-BINDING` | which binding functions a service uses and what backs them |
| `W-BINDING-UNLOADED` | a `bindings/*.rb` that no `use_bindings` names, so its crates are not declared |
| `W-RUST-FN-MISSING` | a `rust_fn` names a function not found in its `rust_file` |
| `N-FILE-UNCHECKED` | a `file` turns a check off with `unchecked:`; the notice names the checks |
| `W-FILE-ARGS-UNCHECKED` | a body names a `file` entry with `entry(...)` but no `entry_args(...)` builds its arguments, so they are not checked |
| `N-OPENAPI` | an `openapi` declaration makes the service serve an OpenAPI document; the notice names the path and how many operations it describes (see [OpenAPI](openapi.md)) |
| `N-VIEW-LOCALS` | a render bound a name its view reads without a `locals:` entry, from a local variable, a `view_local`, a page local, or a layout local; the notice says which, per name (see [Views](views.md), "Locals without `locals:`") |
| `N-DESTROY` | an `execute` written as a relation ending in `destroy` deletes a row and what its model's `dependent:` associations say goes with it; the notice lists every DELETE in the order they run, and the statement is called only inside a `transaction` (see [Database](database.md), "Queries as relations") |
| `N-ATTACHED` | a `has_one_attached` in a `model` derives associations, the `attached(:name)` condition and the statements `attach(...)` runs; the notice lists the statements and their SQL in the order they run (see [Database](database.md), "Attachments") |
| `N-PATH-PARAM-DERIVED` | a params field `in: :path` repeats the type a `resources` declaration derives for that capture (the primary key of the resource's model table); the notice names both, and the line can go unless another route that uses the group needs it |
| `N-DEPRECATED-FEATURE` | **reserved**: declared in the code table, but no `feature` declaration exists in this DSL yet, so nothing emits it |

`N-BINDING` and `N-RUST-INJECTED` carry a short `sha256` of the bytes each input was read from, so a
build against a stale disk copy (an edit not yet saved) is visible in the notice.

```sh
AXUM_DSL_WARN=none make dsl-check                  # hide warnings
AXUM_DSL_NOTICE=N-STR-STRIP-RUBY make dsl-check    # show only these codes
```

An unknown code in `AXUM_DSL_WARN`, `AXUM_DSL_NOTICE`, `--warn` or `--notice` is an error.

The shim catalog (`spec/shims/string.yml`) carries the same code the compiler emits, so a generated skill
and the compiler cannot disagree about one.
