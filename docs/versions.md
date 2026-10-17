# Versions

Two version numbers are in play, and they move independently.

_See also: [README](../README.md)._

- **axum_dsl** (this gem) has its own [SemVer](https://semver.org): the minor changes for new DSL features, the major only when
  existing files stop compiling, the patch for fixes. `axum_dsl --version` prints it.
- **axum** (the Rust framework the generated services use) is pinned by minor version. Every generated
  `Cargo.toml` says `axum = { version = "0.8", ... }` — a caret requirement, so any `0.8.x` — and the top
  of every generated `main.rs` says which axum_dsl made it, so a build never moves to a `0.9` that has not
  been through the end-to-end suites. The version verified so far is axum 0.8.9.

| axum_dsl | axum |
|----------|------|
| 0.1.x | 0.8 |

The pin lives in `lib/axum_dsl/emit.rb` (`cargo`), and `AxumDsl::AXUM_VERSION` in
`lib/axum_dsl/version.rb` repeats it for `axum_dsl --version`; the two must be changed together.

To move to a newer axum: change the version in `emit.rb`, change `AXUM_VERSION`, and run `make check`.
Green adds a row to the table. Red names the behaviour that changed.

`AxumDsl::AXUM_VERSION` is the only target-version constant: `exe/axum_dsl --version` prints it, and
`emit.rb` writes the same axum requirement into every generated `Cargo.toml`. The `RMCP_VERSION` constant
and the `rmcp_version` metadata a port carried over are gone, because nothing read them.
