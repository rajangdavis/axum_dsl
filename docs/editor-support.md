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

- a document that a root file splices in with `use_dsl` (a `controller`, `model` or `fragment` file) is compiled
  **from its root**, with the open buffers laid over the files on disk. The root is found by walking up from
  the document's directory: in each directory the `*.axum.rb` files that may be built on their own (not a
  `fragment`, `model` or `controller` file) are tried in name order, and the first whose `use_dsl` lines,
  followed through the files they splice, reach the document is the root. The answer is kept per document
  (checked again at every compile, searched again when the root stops splicing it in; "no root" is kept until
  the document is reopened). A file nothing splices is compiled alone. Only diagnostics that belong to the open
  document are published for it; when the compile stopped on an error in another file, the document gets one
  information-level note at line 1 naming that file, line and message;
- it compiles the open document on `didOpen`, `didChange` and `didSave`, and publishes the compiler's
  errors with their "did you mean" suggestions (also carried in the diagnostic's `data.suggestions`),
  plus the warnings and notices the gates allow; a document that becomes valid publishes an empty list;
- hover comes from the declaration table (`SIG`), so it cannot drift from the compiler: a call's own name
  shows the shape it accepts — arguments, keywords, block, enclosing context — an argument shows the kind
  accepted there, a keyword shows its kind, and a symbol naming a `params` group shows the line it was
  declared at;
- hover inside a body (a route, helper or controller `def`) answers the type the compiler inferred for the
  smallest `--types` entry covering the position: the name (if any), its kind (`parameter`, `local`,
  `expression`, ...) and its type in the spelling `--types` uses. Hover on the name of a call to a declared
  `query` or `execute` shows its kind, `args`, result, where it is declared and the SQL the compiler holds
  (a relation block's SQL is the rendered text; a `destroy` lists its statements in the order they run). The
  statement table comes from the compiled result, so it exists while the project compiles;
- definition (`textDocument/definition`) answers, in the file that holds it: a call to a `query`/`execute`
  -> its declaration; a call to a `def` -> the def (the open file's first); `render :name` -> the view file;
  `params: :Group` and `skip: [:filter]` -> their declarations; `before :name` -> the `def` of that name; a
  `current` reader (`current_user`) -> its `current` declaration. Anything else answers `null`;
- completion is by context: the declarations allowed where the cursor sits (`field` inside a `params`
  block, the top-level calls elsewhere), a field's types after `field :x, `, and its keywords after the
  type. A body block offers nothing yet;
- requests it does not implement (inlay hints, formatting, document symbols, ...) answer
  `null` or an empty list, and unknown requests answer "method not found".

Set `AXUM_DSL_LSP_LOG=FILE` to append everything received and sent to `FILE`, with start/stop lines and any
crash.

Attach it as a separate language server for `*.axum.rb`, language Ruby for highlighting, command `axum_dsl
lsp`, no arguments, stdio.

## What the eventual server will drive

The compiler's signature table (`SIG` in `lib/axum_dsl/schema.rb`) and `Body::ALLOWED_METHODS` already
hold every call, keyword and body method with one sentence each (`lib/axum_dsl/docs.rb`), which is what
the language server, the generated skill and completion read. Diagnostics, hover and completion are
implemented (`test/test_lsp.rb` drives `axum_dsl lsp` as a process and asserts them); inlay hints, formatting and document symbols are still to come, and there is no `make e2e-lsp` yet.
