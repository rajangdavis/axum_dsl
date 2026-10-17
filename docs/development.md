# Development

Building and extending the compiler: the make targets, the tree layout and the design notes.

_See also: [README](../README.md)._

## Makefile

```sh
make check-fast     # dsl-check, rbi-check, test-ruby, typecheck (no Rust builds)
make check-build    # test-ruby-rust, test-diff (the generated-Rust suites)
make check-e2e      # the e2e of the example services
make check          # check-fast, check-build and check-e2e
make test-ruby      # Ruby tests: the whole test/test_*.rb glob (shims, goldens, refusals, LSP, Rust::Int)
make test-ruby-rust # L5 in Ruby: build a generated crate and drive it over HTTP
make test-diff      # generate a Rust test per catalog and binding example, and run cargo test
make dsl-check      # parse and type-check every example, no output files
make probe          # which body constructs compile today
make e2e-NAME       # build one example and talk HTTP to it (add, validate, assets, views, proxy, case, split, hatches, notes, login, tls, dev;
                    # hatches needs printf, tr and sh on PATH, and ruby for one optional check)
make e2e            # e2e-add
make rbi            # regenerate rbi/dsl.rbi from the compiler's signature table
make rbi-helpers    # write sorbet/rbi/axum_dsl/dsl_helpers.rbi from the examples' helpers
make gen-diff       # generate the Rust tests from the shim catalog
make gem-test       # build the gem and install it into a throwaway GEM_HOME
make deps           # bundle install
```

- Every string method in the body language has a catalog entry with literal examples (`spec/shims/`).
  `test-ruby` runs them against real Ruby and `test-diff` is meant to run the same examples against the
  generated Rust, so the two must agree.
- Every refusal the compiler makes is meant to have a file under `test/refusals/` that must be refused
  with that message.
- Every cargo invocation shares one target dir (`CARGO_TARGET_DIR`, default `/tmp/axum_dsl_target`), so
  axum and its dependencies compile once for the whole suite. `RUSTFLAGS ?= -Dwarnings`, so a generated
  crate must build warning-free.
- `check-fast` is `dsl-check rbi-check test-ruby typecheck`, ordered most-informative-first: `dsl-check`
  is the only place `make check` runs the compiler over `examples/*.axum.rb`, so a crash in the compiler
  surfaces before anything that can mask it. A stale `rbi/dsl.rbi` stops `rbi-check`, and
  `test/test_body_surface.rb` re-checks the same rbi inside `test-ruby`, so with either of them first an
  example that will not compile was reported as an rbi failure instead — which is how a
  `String#start_with?` crash in the view scanner stayed hidden through a ladder pass. Run `make rbi` when
  `check-fast` fails on the rbi; `dsl-check` stays first so a compiler crash cannot hide behind it again.

**Wired**: `make test-ruby-rust` runs `test/test_routes.rb` with `AXUM_CARGO=1` (build a generated crate
and drive it over HTTP); without that variable its emitted-text half still runs inside `test-ruby`, and so
do the LSP test and the refusal fixtures. `make test-diff` regenerates `shimcheck/tests/shims.rs` with
`bin/gen_shim_tests` and runs `cargo test` in `shimcheck/`; both that crate and `test/test_routes.rb` are
in the tree now. `make e2e-add` builds `examples/add.axum.rb` to `/tmp/axum_dsl_add-out` and drives it with
`test/e2e_add.sh`, and works when cargo is available. `make dsl-check`, `make test-ruby`, `make rbi`,
`make rbi-check`, `make rbi-helpers(-check)` and `make probe` work today, and `make typecheck` runs
`rbi-check`, `rbi-helpers-check` and then `srb tc` over `sorbet/config`'s `--dir=examples` (every
example) and the rbi dirs — the `rbi/dsl.rbi` body-surface gap it used to fail on is closed
(`test/test_body_surface.rb` holds the rbi current).

## Layout

| Path | What |
|------|------|
| `exe/axum_dsl` | the command |
| `lib/axum_dsl/` | signature table, reader, body transpiler, regex translator, emitter, bindings loader, error mapping, notifications, and the generators (`rbi.rb`, `docs.rb`, `skill.rb`) |
| `lib/axum_dsl/lsp/` | the language server (`lsp.rb`, `server.rb`, `sources.rb`, `analysis.rb`, `hover.rb`, `completion.rb`, `sig_doc.rb`, `position.rb`): diagnostics from the compiler over the open buffer, hover and completion from `SIG`, and the open-buffer registry |
| `spec/shims/string.yml` | the shim catalog: each string method, its Rust template, literal examples |
| `rbi/` | generated Sorbet description of the DSL (do not edit `dsl.rbi`) and a stub for a prism RBI bug |
| `examples/` | the services listed in [Examples](examples.md) |
| `bin/` | `gen_rbi`, `gen_shim_tests`, `probe` |
| `test/` | Ruby tests, the golden files (`golden/`), the refusal fixtures (`refusals/`) and the end-to-end scripts (`e2e_*.sh`) |
| `shimcheck/` | the crate `bin/gen_shim_tests` writes `tests/shims.rs` into; `make test-diff` runs it |

## More

The code comments refer to `SKETCH.md`, `SPEC.md` and `DESIGN.md` (design notes, test plan, shim catalog
format, notifications, regex rules, the compiler's structure and what is unverified). Those files are not
in the tree yet; the references are carried over from `rmcp_dsl` and mark where the port owes
documentation.
