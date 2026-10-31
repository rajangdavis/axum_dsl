# frozen_string_literal: true

module AxumDsl
  # `url_encode(text)`: Ruby's `URI.encode_www_form_component(text)`, the query-parameter escaping Rack applies
  # (Rack::Utils.escape). Rails appends query params this way, so `new_session_url(email_address:
  # "david@37signals.com")` is "/session/new?email_address=david%4037signals.com"; Campfire's redirect to sign-in
  # carries the address in that query. The kept set is Ruby's form-encoding table, not RFC 3986's unreserved set:
  # `*` is kept and `~` is written %7E (`ERB::Util.url_encode` is the other one). The compiler carries the encoder
  # rather than making an app declare Rust.
  module Url
    module_function

    NAME = "url_encode"

    def used?(ir) = ir["builtins"].to_a.include?(NAME)

    # The runtime, written once per crate only when a body calls url_encode.
    def items(ir)
      return [] unless used?(ir)

      <<~'RS'.lines.map(&:chomp)
        // URI.encode_www_form_component(text): Ruby's form-encoding set (A-Za-z0-9 - . _ *) kept, a space as `+`,
        // and every other UTF-8 byte as `%XX` with upper-case hex (so `~` is %7E, not kept as RFC 3986 would).
        fn axum_dsl_url_encode(text: &str) -> String {
            let mut out = String::new();
            for byte in text.bytes() {
                match byte {
                    b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'*' => out.push(byte as char),
                    b' ' => out.push('+'),
                    _ => out.push_str(&format!("%{byte:02X}")),
                }
            }
            out
        }

      RS
    end
  end
end
