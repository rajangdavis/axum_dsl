# frozen_string_literal: true

module AxumDsl
  # The compiler's own HTML sanitiser for a view's `{{ name|sanitize }}` (docs/views.md): an Action Text body
  # carries markup, so escaping it would show the tags and `|raw` would trust them. Ammonia's default allowlist
  # is the surface -- its tags, its href/src attributes and its URL schemes -- with generic `class` allowed
  # because Action Text/Trix uses classes; a tag list of our own is not configurable yet. The helper and its
  # dependency are emitted only into a crate whose views sanitise a value, as Sessions' pieces are.
  module Sanitize
    # One pass over the HTML: ammonia's default builder, with class kept on any element. The call site is
    # path-qualified (`axum_dsl_sanitize`), so it needs no `use`.
    HELPER = <<~'RS'
      fn axum_dsl_sanitize(html: &str) -> String {
          ::ammonia::Builder::default()
              .add_generic_attributes(&["class"])
              .clean(html)
              .to_string()
      }
    RS

    module_function

    def used?(ir) = !!ir["sanitize"]

    # The Cargo.toml dependency line, led by a newline like the others: ammonia only when a view sanitises.
    def deps(ir) = used?(ir) ? "\nammonia = \"4\"" : ""

    # The helper, followed by a blank line, or nothing at all.
    def items(ir)
      return [] unless used?(ir)

      ["// HTML sanitising for `{{ name|sanitize }}` (ammonia): written by the compiler", *HELPER.lines.map(&:chomp), ""]
    end
  end
end