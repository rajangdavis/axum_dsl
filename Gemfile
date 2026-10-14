# frozen_string_literal: true

source "https://rubygems.org"

# Runtime dependencies. Keep these in step with axum_dsl.gemspec. The Gemfile deliberately does not say
# `gemspec`: that makes Bundler treat this directory as an installed gem, and Sorbet then caches its
# rbi/ folder by name and version under ~/.cache/sorbet/gem-rbis. Hook runs from temporary copies of
# the project poisoned that cache with paths that no longer exist, and `srb tc` failed.
# Prism's node classes change between versions, so Gemfile.lock is committed: it is the exact pin.
gem "prism", "~> 1.9"
gem "sorbet-runtime"

group :development, :test do
  gem "minitest"
  gem "sorbet" # srb tc
end
