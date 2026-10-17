# typed: true
# Case conversion backed by the `heck` crate. The Ruby bodies are the reference the tests compare
# the crate against. Acronyms are where they differ ("XMLHttpRequest": heck gives xml_http_request),
# so the examples avoid them on purpose; the crate is what the server runs.
# examples/case.axum.rb loads this with `use_bindings :heck`; `crate "heck", "0.5"` is what puts heck in its Cargo.toml.
module Heck
  extend T::Sig
  extend AxumDsl::BindingDsl

  crate "heck", "0.5"

  rust "heck::ToSnakeCase::to_snake_case(s)"
  sig { params(s: String).returns(String) }
  def self.snake_case(s)
    s.gsub(/([a-z0-9])([A-Z])/, '\1_\2').gsub(/[^A-Za-z0-9]+/, "_").downcase.gsub(/\A_+|_+\z/, "")
  end
  example :snake_case, "HelloWorld fooBar", expect: "hello_world_foo_bar"
  example :snake_case, "already_snake", expect: "already_snake"
  example :snake_case, "  spaced   out  ", expect: "spaced_out"
  example :snake_case, "", expect: ""

  rust "heck::ToKebabCase::to_kebab_case(s)"
  sig { params(s: String).returns(String) }
  def self.kebab_case(s)
    snake_case(s).tr("_", "-")
  end
  example :kebab_case, "HelloWorld fooBar", expect: "hello-world-foo-bar"
  example :kebab_case, "snake_case_input", expect: "snake-case-input"
  example :kebab_case, "", expect: ""

  rust "heck::ToUpperCamelCase::to_upper_camel_case(s)"
  sig { params(s: String).returns(String) }
  def self.upper_camel_case(s)
    s.split(/[^A-Za-z0-9]+|(?<=[a-z0-9])(?=[A-Z])/).reject(&:empty?).map(&:capitalize).join
  end
  example :upper_camel_case, "hello_world foo-bar", expect: "HelloWorldFooBar"
  example :upper_camel_case, "HelloWorld fooBar", expect: "HelloWorldFooBar"
  example :upper_camel_case, "", expect: ""
end
