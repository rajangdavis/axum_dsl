# Editor support

_See also: [README](../README.md)._

Name DSL files `*.axum.rb` and attach them to language Ruby for highlighting. There are two ways to get
the compiler's opinion into an editor.

## The working path: `check --format json --types`

`axum_dsl check FILE --format json` prints one document for a tool to consume: `{ok, file, inputs, notes,
hidden}` or `{ok: false, file, error: {file, line, col, message, suggestions}}`, with exit status 1 on
failure. The error names the valid choices and, for a likely typo, suggests the nearest name
(`suggestions`), which a quick fix can apply.

`--types` adds `types`: `[{line, col, end_line, end_col, kind, type, name?}]`, the type the compiler
inferred for every parameter, local and expression. Lines and columns are 1-based and `end_col` is
exclusive; types read like Sorbet (`String`, `Integer (i64)`, `T.nilable(String)`). This is what an
editor needs to show inferred types over a body. It reads the file named on the command line; the language
server populates `AxumDsl::Lsp::Sources` with the open buffers, so a query about an unsaved file is about
the text being typed.

## The `lsp` subcommand

`axum_dsl lsp` starts a language server on stdin/stdout, Content-Length framed JSON-RPC 2.0, with
**nothing else written to stdout** (diagnostics about the server itself go to stderr). It reports what the
compiler says about the **buffer** you are editing, not the file on disk:

- it compiles the open document on `didOpen`, `didChange` and `didSave`, and publishes the compiler's
  errors with their "did you mean" suggestions (also carried in the diagnostic's `data.suggestions`),
  plus the warnings and notices the gates allow; a document that becomes valid publishes an empty list;
- hover comes from the declaration table (`SIG`), so it cannot drift from the compiler: a call's own name
  shows the shape it accepts — arguments, keywords, block, enclosing context — an argument shows the kind
  accepted there, a keyword shows its kind, and a symbol naming a `params` group shows the line it was
  declared at;
- completion is by context: the declarations allowed where the cursor sits (`field` inside a `params`
  block, the top-level calls elsewhere), a field's types after `field :x, `, and its keywords after the
  type. A body block offers nothing, because that language is Ruby rather than a declaration table;
- requests it does not implement (definition, inlay hints, formatting, document symbols, ...) answer
  `null` or an empty list, and unknown requests answer "method not found".

Set `AXUM_DSL_LSP_LOG=FILE` to append everything received and sent to `FILE`, with start/stop lines and any
crash.

Attach it as a separate language server for `*.axum.rb`, language Ruby for highlighting, command `axum_dsl
lsp`, no arguments, stdio.

## What the eventual server will drive

The compiler's signature table (`SIG` in `lib/axum_dsl/schema.rb`) and `Body::ALLOWED_METHODS` already
hold every call, keyword and body method with one sentence each (`lib/axum_dsl/docs.rb`), which is what
the language server, the generated skill and completion read. Diagnostics, hover and completion are
implemented (`test/test_lsp.rb` drives `axum_dsl lsp` as a process and asserts them); go-to-definition,
inlay hints, formatting and document symbols are still to come, and there is no `make e2e-lsp` yet.
