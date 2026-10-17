# typed: true
# A sixth small example, for one declaration: `use_bindings :heck`, which loads examples/bindings/heck.rb
# (found beside this file, nowhere else). The binding's `crate "heck", "0.5"` is what adds heck to the
# emitted Cargo.toml, so this service needs no rust_crate of its own; the Rust expression on each
# binding method is the implementation, and its Ruby body is only the reference the binding tests use.
# test/e2e_case.sh drives it; the other examples hold 8080, 8091, 8093, 8095 and 8097, so this takes 8081.
server "caser", version: "0.1.0"
set :port, 8081

use_bindings :heck

params :Phrase do
  field :phrase, :string, in: :query
end

get "/snake", params: :Phrase, description: "The phrase in snake_case" do
  text(Heck.snake_case(params[:phrase]))
end

get "/kebab", params: :Phrase, description: "The phrase in kebab-case" do
  text(Heck.kebab_case(params[:phrase]))
end

get "/camel", params: :Phrase, description: "The phrase in UpperCamelCase" do
  text(Heck.upper_camel_case(params[:phrase]))
end
