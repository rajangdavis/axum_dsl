# frozen_string_literal: true

module AxumDsl
  # `crc32(text)`: Ruby's `Zlib.crc32(text)`, the IEEE 802.3 CRC-32 Ruby returns as an unsigned 32-bit
  # Integer. Campfire's avatar palette indexes with it (`Zlib.crc32(user.to_param) % 18`), so the compiler
  # carries the checksum rather than making an app declare Rust for it.
  module Crc32
    module_function

    NAME = "crc32"

    def used?(ir) = ir["builtins"].to_a.include?(NAME)

    # The runtime, written once per crate only when a body calls crc32.
    def items(ir)
      return [] unless used?(ir)

      <<~'RS'.lines.map(&:chomp)
        // Zlib.crc32(text): the IEEE 802.3 CRC-32, as an unsigned 32-bit integer in an i64.
        fn axum_dsl_crc32(text: &str) -> i64 {
            let mut crc: u32 = 0xFFFF_FFFF;
            for byte in text.as_bytes() {
                crc ^= u32::from(*byte);
                for _ in 0..8 {
                    let mask = (crc & 1).wrapping_neg();
                    crc = (crc >> 1) ^ (0xEDB8_8320 & mask);
                }
            }
            i64::from(!crc)
        }

      RS
    end
  end
end
