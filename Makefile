# axum_dsl: a Ruby(ish) DSL that compiles to an axum service in Rust.
#
# Slices, so a gate fits inside one hook timeout:
#   check-fast   Ruby and Sorbet, no Rust
#   check-build  the generated-Rust suites
#   check-e2e    the example services over HTTP
#   check        all three, for the host

.PHONY: probe test-ruby test-ruby-rust gen-diff test-diff dsl-check rbi rbi-check rbi-helpers rbi-helpers-check typecheck check-fast check-build check-e2e check e2e e2e-add gem-test

# Every cargo invocation shares one target dir, so axum and its dependencies compile once
# for the whole suite instead of once per generated crate.
export CARGO_TARGET_DIR := $(CURDIR)/target

# Generated crates are meant to be warning-free; deny rustc warnings in every cargo build
# this Makefile runs. Cargo caps lints for dependencies, so only the generated crate and its
# injected modules are affected.
RUSTFLAGS ?= -Dwarnings
export RUSTFLAGS

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

check-fast: rbi-check typecheck test-ruby

check-build: test-ruby-rust test-diff

check-e2e: e2e

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

rbi-helpers:
	@test -n "$(EXAMPLES)" || { echo "rbi-helpers: no examples yet, nothing to write"; exit 0; }
	ruby exe/axum_dsl rbi $(EXAMPLES) -o $(HELPER_RBI_DIR)

# Fails if the checked-in helper RBI differs from what the examples produce now.
rbi-helpers-check:
	@test -n "$(EXAMPLES)" || { echo "rbi-helpers-check: no examples yet, nothing to check"; exit 0; }
	rm -rf /tmp/axum_dsl_rbi_check && ruby exe/axum_dsl rbi $(EXAMPLES) -o /tmp/axum_dsl_rbi_check
	diff -u $(HELPER_RBI_DIR)/dsl_helpers.rbi /tmp/axum_dsl_rbi_check/dsl_helpers.rbi || { echo "$(HELPER_RBI_DIR)/dsl_helpers.rbi is stale: run make rbi-helpers"; exit 1; }

# `bundle exec`: in CI (and for anyone without a global Sorbet) srb is only in the bundle.
typecheck: rbi-check rbi-helpers-check
	bundle exec srb tc

# Fast gate: parse, type-check and report notifications for every example, no output files.
dsl-check:
	ruby exe/axum_dsl examples/add.axum.rb --check

# Which Ruby the body language compiles today, one construct at a time (no cargo needed).
probe:
	ruby bin/probe

# L5: build the example service and talk HTTP to it.
e2e: e2e-add

e2e-add:
	ruby exe/axum_dsl build examples/add.axum.rb -o /tmp/add-out
	sh test/e2e_add.sh /tmp/add-out

# The gem: build it, install it into a throwaway GEM_HOME and use it from outside the repo.
gem-test:
	gem build axum_dsl.gemspec
	rm -rf /tmp/axum_dsl_gem && GEM_HOME=/tmp/axum_dsl_gem gem install --local axum_dsl-0.1.0.gem