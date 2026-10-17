# axum_dsl: a Ruby(ish) DSL that compiles to an axum service in Rust.
#
# Slices, so a gate fits inside one hook timeout:
#   check-fast   Ruby and Sorbet, no Rust
#   check-build  the generated-Rust suites
#   check-e2e    the example services over HTTP
#   check        all three, for the host

.PHONY: probe test-ruby test-ruby-rust gen-diff test-diff dsl-check rbi rbi-check rbi-helpers rbi-helpers-check typecheck check-fast check-build check-e2e check e2e e2e-add e2e-validate e2e-assets e2e-csrf e2e-login e2e-login-rails e2e-views e2e-proxy e2e-case e2e-split e2e-hatches e2e-notes e2e-tls e2e-dev golden golden-update gem-test

# Every cargo invocation shares one target dir, so axum and its dependencies compile once
# for the whole suite instead of once per generated crate.
# A projected hook tree is a fresh scratch directory on every run, so a target dir
# under $(CURDIR) would compile axum and tokio from scratch each time. Keep it
# outside the tree, where it survives from one run to the next.
export CARGO_TARGET_DIR := $(if $(AXUM_TARGET_DIR),$(AXUM_TARGET_DIR),/tmp/axum_dsl_target)

# Generated crates are meant to be warning-free; deny rustc warnings in every cargo build
# this Makefile runs. Cargo caps lints for dependencies, so only the generated crate and its
# injected modules are affected.
RUSTFLAGS ?= -Dwarnings
export RUSTFLAGS

# The gems this project's checks need (Sorbet, for `typecheck`), installed into the
# container's own gem home. One-time per container image: the raj-dev-gem volume
# persists, so a rebuilt container does not need it again.
deps:
	bundle install

# L1: Ruby shim tests against the catalog.
test-ruby:
	ruby -Ilib -Itest -e 'Dir.glob("test/test_*.rb").sort.each { |f| require "./#{f}" }'

# L5 in Ruby: build a generated crate and drive it over HTTP.
test-ruby-rust:
	AXUM_CARGO=1 ruby -Ilib test/test_routes.rb

# L3: generate Rust tests from the same catalog, then run them.
gen-diff:
	ruby bin/gen_shim_tests

test-diff: gen-diff
	cd shimcheck && cargo test

# Ordered most-informative-first: dsl-check compiles every example, so a crash in the compiler must
# surface before anything that can mask it — a stale `rbi/dsl.rbi` stops rbi-check, and test-ruby
# re-checks that same rbi, so either one ahead of dsl-check would report the rbi and hide the crash.
# typecheck goes last because it needs Sorbet, which a bare container may not have, so a missing
# `srb` cannot hide the Ruby suites or the example checks.
check-fast: dsl-check rbi-check test-ruby typecheck

check-build: test-ruby-rust test-diff

# Each e2e target has its own port (the example's `set :port`) and its own out dir, so `make -j check-e2e`
# runs them concurrently.
check-e2e: e2e-add e2e-validate e2e-assets e2e-csrf e2e-views e2e-proxy e2e-case e2e-split e2e-hatches e2e-notes e2e-login e2e-login-rails e2e-tls e2e-dev

check: check-fast check-build check-e2e

# Sorbet: regenerate the DSL description from the compiler's SIG table, verify it is current,
# and typecheck the example services against it (structure only).
rbi:
	ruby bin/gen_rbi

rbi-check:
	ruby bin/gen_rbi --check

HELPER_RBI_DIR = sorbet/rbi/axum_dsl

# The helper RBI is derived from the examples, so with none there is nothing to write or check.
# The guard retires with the first example: from then on both targets are strict.
EXAMPLES = $(wildcard examples/*.axum.rb)

# One recipe line each: make runs every line in its own shell, so a guard on a line of
# its own stops nothing and the command below it still runs.
rbi-helpers:
	@if [ -z "$(EXAMPLES)" ]; then echo "rbi-helpers: no examples yet, nothing to write"; else ruby exe/axum_dsl rbi $(EXAMPLES) -o $(HELPER_RBI_DIR); fi

# Fails if the checked-in helper RBI differs from what the examples produce now.
rbi-helpers-check:
	@if [ -z "$(EXAMPLES)" ]; then echo "rbi-helpers-check: no examples yet, nothing to check"; else rm -rf /tmp/axum_dsl_rbi_check && ruby exe/axum_dsl rbi $(EXAMPLES) -o /tmp/axum_dsl_rbi_check && diff -u $(HELPER_RBI_DIR)/dsl_helpers.rbi /tmp/axum_dsl_rbi_check/dsl_helpers.rbi || { echo "$(HELPER_RBI_DIR)/dsl_helpers.rbi is stale: run make rbi-helpers"; exit 1; }; fi

# `bundle exec`: in CI (and for anyone without a global Sorbet) srb is only in the bundle.
# `bundle exec` because in CI, and for anyone without a global Sorbet, srb is only in
# the bundle. Override SORBET to run the check another way, or `SORBET=true` to skip it
# where srb is not installed at all.
SORBET ?= bundle exec srb tc

typecheck: rbi-check rbi-helpers-check
	$(SORBET)

# Fast gate: parse, type-check and report notifications for every example, no output files.
dsl-check:
	@test -n "$(EXAMPLES)" || { echo "dsl-check: no examples yet, nothing to check"; exit 0; }
	@for f in $(EXAMPLES); do echo "== $$f"; ruby exe/axum_dsl $$f --check || exit 1; done

# Which Ruby the body language compiles today, one construct at a time (no cargo needed).
probe:
	ruby bin/probe

# L2 golden and the L6 consistency test already run inside test-ruby (the test/test_*.rb glob),
# so this pair only re-pins the expected Rust after an intended emitter change. golden-update
# writes; an agent may run it (the owner, 2026-10-16) and shows the golden diff in its report.
# Do not add `golden` to check-fast: test-ruby would run it twice.
golden:
	ruby -Ilib test/test_golden.rb

golden-update:
	GOLDEN_UPDATE=1 ruby -Ilib test/test_golden.rb

# L5: build the example service and talk HTTP to it.
e2e: e2e-add

# A per-project out dir: rmcp_dsl's e2e_add.sh builds to /tmp/add-out as well, so two
# projects running at once would clobber each other's crate.
e2e-add:
	ruby exe/axum_dsl build examples/add.axum.rb -o /tmp/axum_dsl_add-out
	sh test/e2e_add.sh /tmp/axum_dsl_add-out

# The constrained example: its 400s come from the emitted check(), not from axum's extractor,
# which is the only way that generated validation is ever exercised.
e2e-validate:
	ruby exe/axum_dsl build examples/validate.axum.rb -o /tmp/axum_dsl_validate-out
	sh test/e2e_validate.sh /tmp/axum_dsl_validate-out

# The view example: its own out dir, and the one crate that carries no copied file at all. Its pages are
# compiled into the binary, so test/e2e_views.sh starts it from anywhere and checks that no views/
# directory reached the crate.
e2e-views:
	ruby exe/axum_dsl build examples/views.axum.rb -o /tmp/axum_dsl_views-out
	sh test/e2e_views.sh /tmp/axum_dsl_views-out

# The file-serving example: its own out dir, because a third crate must not clobber the other two, and
# the script starts the binary with this directory as its working directory — which is what the copied
# assets and the emitted ServeDir::new("public") are resolved against.
e2e-assets:
	ruby exe/axum_dsl build examples/assets.axum.rb -o /tmp/axum_dsl_assets-out
	sh test/e2e_assets.sh /tmp/axum_dsl_assets-out

# The CSRF example: `use_layer :csrf` puts a token in a signed cookie and in a form's `authenticity_token`,
# and a write without a matching one is a 403 behind `use_layer :fetch_metadata`. Port 8087 and its own out dir.
e2e-csrf:
	ruby exe/axum_dsl build examples/csrf.axum.rb -o /tmp/axum_dsl_csrf-out
	sh test/e2e_csrf.sh /tmp/axum_dsl_csrf-out

# The proxy example: `use_layer :trace, forwarded: true`, whose log line names the X-Forwarded-For address.
# Its own port (8095) and out dir, like the others.
e2e-proxy:
	ruby exe/axum_dsl build examples/proxy.axum.rb -o /tmp/axum_dsl_proxy-out
	sh test/e2e_proxy.sh /tmp/axum_dsl_proxy-out

# The binding example: `use_bindings :heck`, whose `crate` line must reach the emitted Cargo.toml (the script
# checks it before any HTTP). Port 8081 and its own out dir.
e2e-case:
	ruby exe/axum_dsl build examples/case.axum.rb -o /tmp/axum_dsl_case-out
	sh test/e2e_case.sh /tmp/axum_dsl_case-out

# The use_dsl example: a root file, two fragments and a fragment of a fragment. Port 8082.
e2e-split:
	ruby exe/axum_dsl build examples/split.axum.rb -o /tmp/axum_dsl_split-out
	sh test/e2e_split.sh /tmp/axum_dsl_split-out

# Every escape hatch (rust_crate/item/fn/file, cmd_fn, script_fn, file). Port 8083. The service starts
# subprocesses (printf, tr, sh, ruby), so the host needs them on PATH.
e2e-hatches:
	ruby exe/axum_dsl build examples/hatches.axum.rb -o /tmp/axum_dsl_hatches-out
	sh test/e2e_hatches.sh /tmp/axum_dsl_hatches-out

# The SQLite example: `database`, `record`, `query`/`execute` and a migrations folder. Port 8084 and its own out
# dir; the script runs the service on a fresh database file, restarts it on the same file, then builds a
# second tiny service to check that a query that misses a record field stops the server at startup.
e2e-notes:
	ruby exe/axum_dsl build examples/notes.axum.rb -o /tmp/axum_dsl_notes-out
	sh test/e2e_notes.sh /tmp/axum_dsl_notes-out

# The sessions example: signed cookies, `current`, Bcrypt, `use_layer :fetch_metadata` and `set :rust, :none`. Port 8086
# and its own out dir; the script signs up, logs in and out, and checks the cookie, the guard and a short key.
e2e-login:
	ruby exe/axum_dsl build examples/login.axum.rb -o /tmp/axum_dsl_login-out
	sh test/e2e_login.sh /tmp/axum_dsl_login-out

# The Rails cookie example: `cookies ... format: :rails`, Rails' MessageVerifier value with a Marshal payload,
# strict Base64 and HMAC-SHA1. Port 8096 and its own out dir; test/e2e_login_rails.sh computes a cookie in Ruby
# and checks both directions (the service accepts Rails' value, Ruby verifies the service's).
e2e-login-rails:
	ruby exe/axum_dsl build examples/login_rails.axum.rb -o /tmp/axum_dsl_login_rails-out
	sh test/e2e_login_rails.sh /tmp/axum_dsl_login_rails-out

# The TLS example: `set :listener` names a Rust TLS listener (rust_file, tokio-rustls). Port 8098 and its
# own out dir; the script skips when openssl is absent.
e2e-tls:
	ruby exe/axum_dsl build examples/tls.axum.rb -o /tmp/axum_dsl_tls-out
	sh test/e2e_tls.sh /tmp/axum_dsl_tls-out

# `axum_dsl dev`: edit a small service while it runs and check that it follows. Picks a free port itself.
e2e-dev:
	sh test/e2e_dev.sh

# Build the gem, install it into a throwaway GEM_HOME and use it from outside the repository, as raj's
# `lsp` file runs it (`axum env AXUM_DSL_LSP_LOG=... axum_dsl lsp`): the version, a check, the skill (which
# needs spec/shims/ to have shipped), and a language server that answers initialize and exits on shutdown/exit.
GEM_TMP = /tmp/axum_dsl_gem
LSP_FRAMES = 'Content-Length: 58\r\n\r\n{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}Content-Length: 44\r\n\r\n{"jsonrpc":"2.0","id":2,"method":"shutdown"}Content-Length: 33\r\n\r\n{"jsonrpc":"2.0","method":"exit"}'
gem-test:
	rm -rf $(GEM_TMP) && mkdir -p $(GEM_TMP)
	gem build axum_dsl.gemspec --output $(GEM_TMP)/axum_dsl.gem
	GEM_HOME=$(GEM_TMP)/home gem install --no-document $(GEM_TMP)/axum_dsl.gem
	cd $(GEM_TMP) && GEM_HOME=$(GEM_TMP)/home $(GEM_TMP)/home/bin/axum_dsl --version
	cd $(GEM_TMP) && GEM_HOME=$(GEM_TMP)/home $(GEM_TMP)/home/bin/axum_dsl check $(CURDIR)/examples/add.axum.rb
	cd $(GEM_TMP) && GEM_HOME=$(GEM_TMP)/home $(GEM_TMP)/home/bin/axum_dsl skill -o $(GEM_TMP)/skill
	cd $(GEM_TMP) && printf $(LSP_FRAMES) | GEM_HOME=$(GEM_TMP)/home timeout 30 $(GEM_TMP)/home/bin/axum_dsl lsp > $(GEM_TMP)/lsp.out
	grep -q '"capabilities"' $(GEM_TMP)/lsp.out || { echo "gem-test: axum_dsl lsp did not answer initialize:"; cat $(GEM_TMP)/lsp.out; exit 1; }
