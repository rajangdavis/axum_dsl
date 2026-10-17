# Bindings

Typed Rust-backed functions for a project, plus injected Rust and subprocesses.

_See also: [README](../README.md)._

A binding is a Ruby file that gives the compiler a typed function backed by a Rust crate (or compiled from
Ruby). The compiler ships none: they belong to the project. To use one, put a `bindings/` folder in the same
directory as the DSL file, with `bindings/NAME.rb` in it; `use_bindings :name` loads it from there (nothing is
searched beyond that folder), and a body calls it as `Module.method(args)`. A missing file is an error that names
the path it looked for.

The repository ships one example binding, `examples/bindings/heck.rb` (case conversion backed by the `heck`
crate), used by `examples/case.axum.rb` and checked end to end by `make e2e-case`; its `crate "heck", "0.5"` line is
what puts heck in the emitted `Cargo.toml`. A smaller binding file looks like this:

```ruby
# bindings/words.rb, in the same directory as the DSL file
module Words
  extend T::Sig
  extend AxumDsl::BindingDsl

  sig { params(s: String).returns(String) }
  def self.shout(s) = s.upcase + "!"
  example :shout, "hello", expect: "HELLO!"
end
```

- `sig` gives the types: `String`, `Float`, `I32`, `I64`, `T::Boolean`, `T::Array[String]`,
  `T::Array[I64]`, `T::Array[Float]`, and `T.nilable(...)` of those, for a return or a parameter. A
  nil-able parameter arrives as an owned `Option`, and a call may pass `nil`, a plain value or a nil-able
  one.
- Without a `rust` line the Ruby body is compiled to Rust and is the implementation. With
  `rust "heck::ToSnakeCase::to_snake_case(s)"` above the method, that Rust expression does the work and the
  Ruby body is only the reference the tests compare it against. `no_reference "why"` marks a function with
  no Ruby stand-in (an HTML parser, DNS).
- `crate "heck", "0.5"` adds a Cargo dependency. `example :method, args..., expect: value` documents a
  function; the test generators in the compiler's repository run examples, the compiler itself only reads
  the types.
- A binding may own a type with `class Value < AxumDsl::Opaque; type_rust "serde_json::Value", wire: true; end`.
  The DSL holds values of it, passes them to that binding's functions and, with `wire: true`, takes them as
  a `field`. A **record** also lists its fields after `type_rust` (`field :text, String`), which a body
  reads (`row.text`); the generated service checks each field against the Rust struct.

**A binding never fails by itself.** A nil-able return type (`T.nilable(String)`,
`T.nilable(T::Array[String])`) means "does not exist" or "does not parse", and the service decides what that
means: `Words.shout(x) || ""` to carry on, `|| raise("bad input")` to fail the request, `.nil?` to test. A
binding's opaque type is owned by the module that declares it, so a second binding cannot name it — keep the
type and the functions that use it in one binding.

The compiler only parses bindings; it never runs them.

## Injected Rust and subprocesses

Use Rust or call another program:

```ruby
rust_crate "heck", "0.5"                                 # a Cargo dependency
rust_item <<~'RS'                                        # verbatim top-level Rust
  fn to_snake(s: &str) -> String { use heck::ToSnakeCase; s.to_snake_case() }
RS
rust_fn :to_snake, args: [:string], returns: :string     # its signature, checked by the compiler

rust_file "rust/shout.rs", as: :loud                     # an existing file, copied in as a module

cmd_fn :run_upper, program: "tr", argv: ["a-z", "A-Z"], args: [:string], returns: :string, pass: :stdin
script_fn :run_echo, interpreter: "sh", args: [:string], returns: :string, code: <<~'SH'
  printf '%s' "$1"
SH

file "python/x.py", as: :x, entries: %i[place]           # read on each call, with file_text(:x)
```

`rust_crate "name", "1", features: ["a", "b"], default_features: false` writes the dependency as a table
(`name = { version = "1", default-features = false, features = ["a", "b"] }`); `features:` is a non-empty list
of names made of letters, digits and `_ + . -`, each once. Without either keyword the line stays `name = "1"`.
`examples/tls.axum.rb` uses them to pick the `ring` provider for `tokio-rustls`.

A `rust_fn`'s declared name is the Rust function's own name: `rust_fn :to_snake, args: [:string], returns:
:string, from: :loud` finds `fn to_snake` inside the `loud` module (the `rust_file` with `as: :loud`), and
`rust(:to_snake, ...)` is how a body calls it — so the declared name must match the Rust function exactly.
`returns:` takes the helper types, so `returns: :string?` (or `:i64?`, `:string_list?`, ...) declares a
function returning `Option<...>`, and a body handles the nil as with any nil-able value
(`rust(:reply, text) || "no reply"`) instead of agreeing on a sentinel like `""`.

A body calls them as `rust(:name, args)`. Subprocess arguments are separate argv entries or stdin, never
spliced into shell text; the generated service runs the program with a timeout, an output cap and a
minimal environment. There is no sandbox. Every use prints a notice (`N-RUST-INJECTED`, `N-EXEC-INJECTED`)
so you can see how much of a service is not Ruby.

`file "path", as: :name` names a file beside the DSL file. The compiler reads it to check it, and copies it
byte for byte into the emitted crate at the same relative path (like a `static` directory), so the binary reads
`path` from its working directory, the crate directory, on each call; editing the original needs a rebuild to
reach the crate. A file, `static` or `serve_file` path may not be `Cargo.toml`, `Cargo.lock`, `axum_dsl.map.json` or
anything under `src/` or `target/`: those are the crate's own, and the compiler refuses the path rather than
overwrite them. `env:` gives an environment variable that
overrides the path at runtime, and `unchecked:` turns a check off. The compiler accepts a file's
`entries:` without checking them against the file, and `entry_args` emits `serde_json`, which the emitted
crate depends on.

Every one of these is exercised by `examples/hatches.axum.rb` (`rust_crate`, `rust_item`, `rust_fn`, `rust_file`
with `examples/rust/shout.rs`, `cmd_fn`, `script_fn` with `sh` and `ruby`, and `file` read with `file_text`),
which `test/e2e_hatches.sh` drives through `make e2e-hatches`; the subprocess routes there are given values
meant to break a shell (`$HOME`, `;echo pwned`) to show they arrive as argv or stdin. Splitting a service across
files with `use_dsl` is shown by `examples/split.axum.rb` and its fragments in `examples/split/`
(`make e2e-split`); the fragments sit in a sub-folder so the `examples/*.axum.rb` glob never builds one directly.
The `hatches` crate carries its `file` as `hatches/motd.txt` and reads it relative to the working directory,
so the crate and its binary can move together to another machine; `main.rs` has a golden.
