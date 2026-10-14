# frozen_string_literal: true

require_relative "lib/axum_dsl/version"

Gem::Specification.new do |spec|
  spec.name = "axum_dsl"
  spec.version = AxumDsl::VERSION
  spec.authors = ["rajangdavis"]
  spec.email = ["rajangdavis@gmail.com"]

  spec.summary = "Write MCP servers as strict Ruby and compile them to Rust."
  spec.description = "A compiler from a small Ruby DSL to Rust MCP server crates (rmcp). It has a command " \
                     "line (check, build, run, skill), escape hatches for subprocesses, bindings and injected " \
                     "Rust, and writes an agent skill that teaches the DSL."
  # Tested on the version in .tool-versions; loosen it once an older Ruby has run `make check`.
  spec.required_ruby_version = ">= 4.0"
  spec.license = "AGPL-3.0-only"
  spec.metadata["rubygems_mfa_required"] = "true"
  spec.metadata["rmcp_version"] = AxumDsl::RMCP_VERSION # the rmcp the servers it generates are built against
  spec.homepage = "https://github.com/rajangdavis/axum_dsl"
  spec.metadata["source_code_uri"] = "https://github.com/rajangdavis/axum_dsl"

  # Bindings are not shipped: they belong to the project that uses them (a bindings/ folder next to the DSL
  # file; examples/bindings/ shows the format). The skill generator reads spec/shims/.
  spec.files = Dir["{exe,lib}/**/*", "spec/shims/*.yml", "docs/**/*.md", "README.md", "LICENSE*"].select { |f| File.file?(f) }
  spec.bindir = "exe"
  spec.executables = ["axum_dsl"]
  spec.require_paths = ["lib"]

  # Keep these in step with the Gemfile (which lists them directly). Prism's node classes change
  # between versions, so it is pinned to the series Gemfile.lock
  # resolved (1.9.x); widen it only after `make check` passes on the newer one.
  spec.add_dependency "prism", "~> 1.9"
  spec.add_dependency "sorbet-runtime", ">= 0.5"
end
