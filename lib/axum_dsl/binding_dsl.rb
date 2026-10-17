# frozen_string_literal: true

# The runtime half of a binding file. The COMPILER never runs bindings (it parses them), so these
# macros do nothing. Running a binding matters only for its Ruby bodies: tests execute them as the
# reference implementation and compare the Rust against them.
begin
  require "sorbet-runtime"
rescue LoadError
  # Without sorbet-runtime, `sig` becomes a no-op so bindings still run.
  module T
    module Sig
      def sig(*, &_block) = nil
    end
  end
end

# Sorbet sees these as type aliases of Integer (rbi/dsl.rbi); the compiler reads the names.
::I32 = Integer unless defined?(::I32)
::I64 = Integer unless defined?(::I64)

module AxumDsl
  # A type a binding owns: the DSL passes values of it between binding functions, and the Rust type behind it is
  # never looked into. `wire: true` promises that the Rust type is serde Serialize + Deserialize and schemars
  # JsonSchema, which is what lets it be a tool field or part of a result.
  #
  #   class Value < AxumDsl::Opaque
  #     type_rust "serde_json::Value", wire: true
  #   end
  #
  # A record also lists the fields the DSL may read (`field :text, String`), after type_rust.
  class Opaque
    def self.type_rust(_rust, wire: false) = nil
    def self.field(_name, _type) = nil
  end

  module BindingDsl
    def crate(_name, _version) = nil
    def rust(_template, async: false) = nil
    def no_reference(_reason) = nil
    def example(_method, *_args, expect:) = nil
  end
end
