# frozen_string_literal: true

# Executable shims for Rust builtins. See SPEC.md. Native Ruby values keep Ruby
# behaviour; Rust::* types behave as the Rust standard library does.
module Rust; end

require_relative "rust/str"
require_relative "rust/int"
