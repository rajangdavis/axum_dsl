# frozen_string_literal: true

module AxumDsl
  # `qr_code_svg(text)` and `urlsafe_decode64(text)`: what Campfire's QrCodeController (`GET /qr_code/:id`) does with
  # its path segment, `RQRCode::QRCode.new(Base64.urlsafe_decode64(id)).as_svg(viewbox: true, fill: :white, color: :black)`.
  # The SVG has to be byte-identical to the gem's (the parity harness hashes it), so the runtime follows rqrcode_core
  # 2.1.0 and rqrcode 3.2.0 rather than the QR spec's optimal choices: one segment in the first of numeric,
  # alphanumeric and 8-bit byte mode that fits the text, error correction level H, the smallest version whose capacity
  # is strictly greater than the segment's bits, and the mask with the fewest lost points as the gem scores them
  # (including its floating-point dark-ratio term). Both are nil-able: a text too long for version 40 (rqrcode raises)
  # and a Base64 that Ruby's urlsafe_decode64 refuses, or whose bytes are not UTF-8 text, give no value.
  module Qr
    module_function

    DECODE = "urlsafe_decode64"
    SVG = "qr_code_svg"

    def used?(ir) = ir["builtins"].to_a.include?(SVG) || ir["builtins"].to_a.include?(DECODE)

    # The runtime, written once per crate and only for the calls a body makes.
    def items(ir)
      out = []
      out.concat(DECODE_RS.lines.map(&:chomp)) << "" if ir["builtins"].to_a.include?(DECODE)
      out.concat(QR_RS.lines.map(&:chomp)) << "" if ir["builtins"].to_a.include?(SVG)
      out
    end

    DECODE_RS = <<~'RS'
      // Base64.urlsafe_decode64(text): pad a missing tail, map -_ to +/, then strict_decode64 (length a multiple of
      // four, padding only at the end, unused bits zero). None where Ruby raises ArgumentError, or when the bytes are
      // not UTF-8 text.
      fn axum_dsl_urlsafe_decode64(text: &str) -> Option<String> {
          let mut chars: Vec<u8> = text.bytes().collect();
          if chars.last() != Some(&b'=') && chars.len() % 4 != 0 {
              while chars.len() % 4 != 0 {
                  chars.push(b'=');
              }
          }
          let chars: Vec<u8> = chars.into_iter().map(|b| match b { b'-' => b'+', b'_' => b'/', other => other }).collect();
          if chars.len() % 4 != 0 {
              return None;
          }
          let value = |b: u8| -> Option<u32> {
              match b {
                  b'A'..=b'Z' => Some(u32::from(b - b'A')),
                  b'a'..=b'z' => Some(u32::from(b - b'a') + 26),
                  b'0'..=b'9' => Some(u32::from(b - b'0') + 52),
                  b'+' => Some(62),
                  b'/' => Some(63),
                  _ => None,
              }
          };
          let mut out: Vec<u8> = Vec::new();
          let groups = chars.len() / 4;
          for (index, group) in chars.chunks(4).enumerate() {
              let last = index + 1 == groups;
              let pad = group.iter().rev().take_while(|&&b| b == b'=').count();
              if pad > 2 || (pad > 0 && !last) {
                  return None;
              }
              let mut bits: u32 = 0;
              for &b in &group[..4 - pad] {
                  bits = (bits << 6) | value(b)?;
              }
              bits <<= 6 * pad as u32;
              match pad {
                  0 => out.extend_from_slice(&[(bits >> 16) as u8, (bits >> 8) as u8, bits as u8]),
                  1 => {
                      if bits & 0xFF != 0 {
                          return None;
                      }
                      out.extend_from_slice(&[(bits >> 16) as u8, (bits >> 8) as u8]);
                  }
                  _ => {
                      if bits & 0xFFFF != 0 {
                          return None;
                      }
                      out.push((bits >> 16) as u8);
                  }
              }
          }
          String::from_utf8(out).ok()
      }
    RS

    QR_RS = <<~'RS'
      // RQRCode::QRCode.new(text).as_svg(viewbox: true, fill: :white, color: :black): rqrcode_core 2.1.0's encoder and
      // rqrcode 3.2.0's Rect SVG, byte for byte. None where the text does not fit version 40.
      fn axum_dsl_qr_code_svg(text: &str) -> Option<String> {
          axum_dsl_qr::svg(text.as_bytes())
      }

      #[allow(dead_code)]
      mod axum_dsl_qr {
          const ALPHANUMERIC: &[u8] = b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:";
          // QRERRORCORRECTLEVEL[:h]
          const LEVEL_H: u32 = 2;
          // QRMAXBITS[:h]
          const MAX_BITS_H: [usize; 40] = [
              72, 128, 208, 288, 368, 480, 528, 688, 800, 976, 1120, 1264, 1440, 1576, 1784, 2024, 2264, 2504, 2728, 3080,
              3248, 3536, 3712, 4112, 4304, 4768, 5024, 5288, 5608, 5960, 6344, 6760, 7208, 7688, 7888, 8432, 8768, 9136,
              9776, 10208,
          ];
          // The H rows of QRRSBlock::RS_BLOCK_TABLE: (count, total, data) groups.
          const RS_BLOCKS_H: [&[usize]; 40] = [
              &[1, 26, 9], &[1, 44, 16], &[2, 35, 13], &[4, 25, 9], &[2, 33, 11, 2, 34, 12], &[4, 43, 15],
              &[4, 39, 13, 1, 40, 14], &[4, 40, 14, 2, 41, 15], &[4, 36, 12, 4, 37, 13], &[6, 43, 15, 2, 44, 16],
              &[3, 36, 12, 8, 37, 13], &[7, 42, 14, 4, 43, 15], &[12, 33, 11, 4, 34, 12], &[11, 36, 12, 5, 37, 13],
              &[11, 36, 12, 7, 37, 13], &[3, 45, 15, 13, 46, 16], &[2, 42, 14, 17, 43, 15], &[2, 42, 14, 19, 43, 15],
              &[9, 39, 13, 16, 40, 14], &[15, 43, 15, 10, 44, 16], &[19, 46, 16, 6, 47, 17], &[34, 37, 13],
              &[16, 45, 15, 14, 46, 16], &[30, 46, 16, 2, 47, 17], &[22, 45, 15, 13, 46, 16], &[33, 46, 16, 4, 47, 17],
              &[12, 45, 15, 28, 46, 16], &[11, 45, 15, 31, 46, 16], &[19, 45, 15, 26, 46, 16], &[23, 45, 15, 25, 46, 16],
              &[23, 45, 15, 28, 46, 16], &[19, 45, 15, 35, 46, 16], &[11, 45, 15, 46, 46, 16], &[59, 46, 16, 1, 47, 17],
              &[22, 45, 15, 41, 46, 16], &[2, 45, 15, 64, 46, 16], &[24, 45, 15, 46, 46, 16], &[42, 45, 15, 32, 46, 16],
              &[10, 45, 15, 67, 46, 16], &[20, 45, 15, 61, 46, 16],
          ];
          // QRUtil::PATTERN_POSITION_TABLE
          const PATTERN_POSITIONS: [&[usize]; 40] = [
              &[], &[6, 18], &[6, 22], &[6, 26], &[6, 30], &[6, 34], &[6, 22, 38], &[6, 24, 42], &[6, 26, 46], &[6, 28, 50],
              &[6, 30, 54], &[6, 32, 58], &[6, 34, 62], &[6, 26, 46, 66], &[6, 26, 48, 70], &[6, 26, 50, 74],
              &[6, 30, 54, 78], &[6, 30, 56, 82], &[6, 30, 58, 86], &[6, 34, 62, 90], &[6, 28, 50, 72, 94],
              &[6, 26, 50, 74, 98], &[6, 30, 54, 78, 102], &[6, 28, 54, 80, 106], &[6, 32, 58, 84, 110],
              &[6, 30, 58, 86, 114], &[6, 34, 62, 90, 118], &[6, 26, 50, 74, 98, 122], &[6, 30, 54, 78, 102, 126],
              &[6, 26, 52, 78, 104, 130], &[6, 30, 56, 82, 108, 134], &[6, 34, 60, 86, 112, 138],
              &[6, 30, 58, 86, 114, 142], &[6, 34, 62, 90, 118, 146], &[6, 30, 54, 78, 102, 126, 150],
              &[6, 24, 50, 76, 102, 128, 154], &[6, 28, 54, 80, 106, 132, 158], &[6, 32, 58, 84, 110, 136, 162],
              &[6, 26, 54, 82, 110, 138, 166], &[6, 30, 58, 86, 114, 142, 170],
          ];
          const G15: u32 = (1 << 10) | (1 << 8) | (1 << 5) | (1 << 4) | (1 << 2) | (1 << 1) | 1;
          const G18: u32 = (1 << 12) | (1 << 11) | (1 << 10) | (1 << 9) | (1 << 8) | (1 << 5) | (1 << 2) | 1;
          const G15_MASK: u32 = (1 << 14) | (1 << 12) | (1 << 10) | (1 << 4) | (1 << 1);

          type Grid = Vec<Vec<Option<bool>>>;

          // QRSegment: the whole input in one mode (1 numeric, 2 alphanumeric, 4 byte).
          fn mode_of(data: &[u8]) -> u32 {
              if data.iter().all(|b| b.is_ascii_digit()) {
                  1
              } else if data.iter().all(|b| ALPHANUMERIC.contains(b)) {
                  2
              } else {
                  4
              }
          }

          // QRUtil.get_length_in_bits
          fn length_in_bits(mode: u32, version: usize) -> usize {
              let macro_version = if version <= 9 { 0 } else if version <= 26 { 1 } else { 2 };
              match mode {
                  1 => [10, 12, 14][macro_version],
                  2 => [9, 11, 13][macro_version],
                  _ => [8, 16, 16][macro_version],
              }
          }

          // QRSegment#size(version): the bits needed, mode indicator and length included.
          fn segment_size(data: &[u8], mode: u32, version: usize) -> usize {
              let length = data.len();
              let content = match mode {
                  1 => (length / 3) * 10 + if length % 3 == 0 { 0 } else { [0, 4, 7][length % 3] },
                  2 => (length / 2) * 11 + if length % 2 == 0 { 0 } else { 6 },
                  _ => length * 8,
              };
              4 + length_in_bits(mode, version) + content
          }

          struct BitBuffer {
              buffer: Vec<u8>,
              length: usize,
          }

          impl BitBuffer {
              fn put(&mut self, num: u32, length: usize) {
                  for i in 0..length {
                      self.put_bit((num >> (length - i - 1)) & 1 == 1);
                  }
              }

              fn put_bit(&mut self, bit: bool) {
                  let index = self.length / 8;
                  if self.buffer.len() <= index {
                      self.buffer.push(0);
                  }
                  if bit {
                      self.buffer[index] |= 0x80 >> (self.length % 8);
                  }
                  self.length += 1;
              }
          }

          fn write_segment(data: &[u8], mode: u32, version: usize, buffer: &mut BitBuffer) {
              buffer.put(mode, 4);
              buffer.put(data.len() as u32, length_in_bits(mode, version));
              match mode {
                  1 => {
                      for chunk in data.chunks(3) {
                          let code = chunk.iter().fold(0u32, |acc, b| acc * 10 + u32::from(b - b'0'));
                          buffer.put(code, [0, 4, 7, 10][chunk.len()]);
                      }
                  }
                  2 => {
                      let index = |b: &u8| ALPHANUMERIC.iter().position(|a| a == b).unwrap_or(0) as u32;
                      for pair in data.chunks(2) {
                          if pair.len() == 2 {
                              buffer.put(index(&pair[0]) * 45 + index(&pair[1]), 11);
                          } else {
                              buffer.put(index(&pair[0]), 6);
                          }
                      }
                  }
                  _ => {
                      for &b in data {
                          buffer.put(u32::from(b), 8);
                      }
                  }
              }
          }

          // QRMath: the GF(256) exp and log tables.
          struct Galois {
              exp: [u32; 256],
              log: [u32; 256],
          }

          impl Galois {
              fn new() -> Self {
                  let mut exp = [0u32; 256];
                  let mut log = [0u32; 256];
                  for i in 0..8 {
                      exp[i] = 1 << i;
                  }
                  for i in 8..256 {
                      exp[i] = exp[i - 4] ^ exp[i - 5] ^ exp[i - 6] ^ exp[i - 8];
                  }
                  for i in 0..255 {
                      log[exp[i] as usize] = i as u32;
                  }
                  Self { exp, log }
              }

              fn glog(&self, n: u32) -> i64 {
                  i64::from(self.log[n.max(1) as usize])
              }

              fn gexp(&self, mut n: i64) -> u32 {
                  while n < 0 {
                      n += 255;
                  }
                  while n >= 256 {
                      n -= 255;
                  }
                  self.exp[n as usize]
              }
          }

          // QRPolynomial: the leading zeros drop, then `shift` zeros are appended.
          fn polynomial(num: &[u32], shift: usize) -> Vec<u32> {
              let offset = num.iter().take_while(|&&n| n == 0).count();
              let mut values = num[offset..].to_vec();
              values.resize(num.len() - offset + shift, 0);
              values
          }

          fn multiply(a: &[u32], b: &[u32], gf: &Galois) -> Vec<u32> {
              let mut num = vec![0u32; a.len() + b.len() - 1];
              for (i, &x) in a.iter().enumerate() {
                  for (j, &y) in b.iter().enumerate() {
                      num[i + j] ^= gf.gexp(gf.glog(x) + gf.glog(y));
                  }
              }
              polynomial(&num, 0)
          }

          fn modulo(mut current: Vec<u32>, other: &[u32], gf: &Galois) -> Vec<u32> {
              while current.len() >= other.len() {
                  let ratio = gf.glog(current[0]) - gf.glog(other[0]);
                  let mut num = current.clone();
                  for (i, &value) in other.iter().enumerate() {
                      num[i] ^= gf.gexp(gf.glog(value) + ratio);
                  }
                  current = polynomial(&num, 0);
              }
              current
          }

          // QRCode.create_data: the data and error correction codewords, interleaved.
          fn create_data(data: &[u8], mode: u32, version: usize) -> Vec<u8> {
              let mut blocks: Vec<(usize, usize)> = Vec::new();
              for group in RS_BLOCKS_H[version - 1].chunks(3) {
                  for _ in 0..group[0] {
                      blocks.push((group[1], group[2]));
                  }
              }
              let max_data_bits = blocks.iter().map(|(_, d)| *d).sum::<usize>() * 8;
              let mut buffer = BitBuffer { buffer: Vec::new(), length: 0 };
              write_segment(data, mode, version, &mut buffer);
              if buffer.length + 4 <= max_data_bits {
                  buffer.put(0, 4);
              }
              while buffer.length % 8 != 0 {
                  buffer.put_bit(false);
              }
              while buffer.length < max_data_bits {
                  buffer.put(0xEC, 8);
                  if buffer.length < max_data_bits {
                      buffer.put(0x11, 8);
                  }
              }
              let gf = Galois::new();
              let mut offset = 0;
              let mut dc_data: Vec<Vec<u32>> = Vec::new();
              let mut ec_data: Vec<Vec<u32>> = Vec::new();
              for &(total, data_count) in &blocks {
                  let ec_count = total - data_count;
                  let dc: Vec<u32> = buffer.buffer[offset..offset + data_count].iter().map(|&b| u32::from(b)).collect();
                  offset += data_count;
                  let mut rs_poly = polynomial(&[1], 0);
                  for i in 0..ec_count {
                      rs_poly = multiply(&rs_poly, &polynomial(&[1, gf.gexp(i as i64)], 0), &gf);
                  }
                  let ec_length = rs_poly.len() - 1;
                  let mod_poly = modulo(polynomial(&dc, ec_length), &rs_poly, &gf);
                  let ec: Vec<u32> = (0..ec_length)
                      .map(|i| {
                          let index = i as i64 + mod_poly.len() as i64 - ec_length as i64;
                          if index >= 0 { mod_poly[index as usize] } else { 0 }
                      })
                      .collect();
                  dc_data.push(dc);
                  ec_data.push(ec);
              }
              let mut out = Vec::new();
              for codewords in [&dc_data, &ec_data] {
                  let longest = codewords.iter().map(|c| c.len()).max().unwrap_or(0);
                  for i in 0..longest {
                      for block in codewords.iter() {
                          if let Some(&value) = block.get(i) {
                              out.push(value as u8);
                          }
                      }
                  }
              }
              out
          }

          fn bch_digit(mut data: u32) -> i32 {
              let mut digit = 0;
              while data != 0 {
                  digit += 1;
                  data >>= 1;
              }
              digit
          }

          fn bch_format_info(data: u32) -> u32 {
              let mut d = data << 10;
              while bch_digit(d) - bch_digit(G15) >= 0 {
                  d ^= G15 << (bch_digit(d) - bch_digit(G15));
              }
              ((data << 10) | d) ^ G15_MASK
          }

          fn bch_version(data: u32) -> u32 {
              let mut d = data << 12;
              while bch_digit(d) - bch_digit(G18) >= 0 {
                  d ^= G18 << (bch_digit(d) - bch_digit(G18));
              }
              (data << 12) | d
          }

          // QRMASKCOMPUTATIONS
          fn mask(pattern: u32, i: usize, j: usize) -> bool {
              match pattern {
                  0 => (i + j) % 2 == 0,
                  1 => i % 2 == 0,
                  2 => j % 3 == 0,
                  3 => (i + j) % 3 == 0,
                  4 => (i / 2 + j / 3) % 2 == 0,
                  5 => ((i * j) % 2 + (i * j) % 3) == 0,
                  6 => ((i * j) % 2 + (i * j) % 3) % 2 == 0,
                  _ => ((i * j) % 3 + (i + j) % 2) % 2 == 0,
              }
          }

          fn probe_pattern(grid: &mut Grid, row: usize, col: usize) {
              let count = grid.len() as i64;
              for r in -1i64..=7 {
                  let y = row as i64 + r;
                  if y < 0 || y >= count {
                      continue;
                  }
                  for c in -1i64..=7 {
                      let x = col as i64 + c;
                      if x < 0 || x >= count {
                          continue;
                      }
                      let vertical = (0..=6).contains(&r) && (c == 0 || c == 6);
                      let horizontal = (0..=6).contains(&c) && (r == 0 || r == 6);
                      let square = (2..=4).contains(&r) && (2..=4).contains(&c);
                      grid[y as usize][x as usize] = Some(vertical || horizontal || square);
                  }
              }
          }

          fn adjust_pattern(grid: &mut Grid, version: usize) {
              let positions = PATTERN_POSITIONS[version - 1];
              for &row in positions {
                  for &col in positions {
                      if grid[row][col].is_some() {
                          continue;
                      }
                      for r in -2i64..=2 {
                          for c in -2i64..=2 {
                              let part = r.abs() == 2 || c.abs() == 2 || (r == 0 && c == 0);
                              grid[(row as i64 + r) as usize][(col as i64 + c) as usize] = Some(part);
                          }
                      }
                  }
              }
          }

          fn timing_pattern(grid: &mut Grid) {
              let count = grid.len();
              for i in 8..count - 8 {
                  grid[i][6] = Some(i % 2 == 0);
                  grid[6][i] = Some(i % 2 == 0);
              }
          }

          fn version_info(grid: &mut Grid, version: usize, test: bool) {
              let count = grid.len();
              let bits = bch_version(version as u32);
              for i in 0..18 {
                  let dark = !test && (bits >> i) & 1 == 1;
                  grid[i / 3][i % 3 + count - 8 - 3] = Some(dark);
                  grid[i % 3 + count - 8 - 3][i / 3] = Some(dark);
              }
          }

          fn format_info(grid: &mut Grid, test: bool, pattern: u32) {
              let count = grid.len();
              let bits = bch_format_info((LEVEL_H << 3) | pattern);
              for i in 0..15 {
                  let dark = !test && (bits >> i) & 1 == 1;
                  let row = if i < 6 { i } else if i < 8 { i + 1 } else { count - 15 + i };
                  grid[row][8] = Some(dark);
                  let col = if i < 8 { count - i - 1 } else if i < 9 { 15 - i } else { 15 - i - 1 };
                  grid[8][col] = Some(dark);
              }
              grid[count - 8][8] = Some(!test);
          }

          fn map_data(grid: &mut Grid, data: &[u8], pattern: u32) {
              let count = grid.len() as i64;
              let mut inc: i64 = -1;
              let mut row: i64 = count - 1;
              let mut bit_index: i32 = 7;
              let mut byte_index = 0;
              let mut col = count - 1;
              while col >= 1 {
                  let c0 = if col <= 6 { col - 1 } else { col };
                  loop {
                      for c in 0..2 {
                          let x = (c0 - c) as usize;
                          let y = row as usize;
                          if grid[y][x].is_none() {
                              let mut dark = byte_index < data.len() && (data[byte_index] >> bit_index) & 1 == 1;
                              if mask(pattern, y, x) {
                                  dark = !dark;
                              }
                              grid[y][x] = Some(dark);
                              bit_index -= 1;
                              if bit_index == -1 {
                                  byte_index += 1;
                                  bit_index = 7;
                              }
                          }
                      }
                      row += inc;
                      if row < 0 || count <= row {
                          row -= inc;
                          inc = -inc;
                          break;
                      }
                  }
                  col -= 2;
              }
          }

          // QRUtil.get_lost_points. The dark-ratio term is a Float in Ruby, so the total is too.
          fn lost_points(modules: &[Vec<bool>]) -> f64 {
              let count = modules.len();
              let max = count - 1;
              let mut points: i64 = 0;
              for row in 0..count {
                  for col in 0..count {
                      let dark = modules[row][col];
                      let mut same = 0;
                      if row > 0 {
                          let above = &modules[row - 1];
                          same += (col > 0 && dark == above[col - 1]) as i64;
                          same += (dark == above[col]) as i64;
                          same += (col < max && dark == above[col + 1]) as i64;
                      }
                      same += (col > 0 && dark == modules[row][col - 1]) as i64;
                      same += (col < max && dark == modules[row][col + 1]) as i64;
                      if row < max {
                          let below = &modules[row + 1];
                          same += (col > 0 && dark == below[col - 1]) as i64;
                          same += (dark == below[col]) as i64;
                          same += (col < max && dark == below[col + 1]) as i64;
                      }
                      if same > 5 {
                          points += 3 + same - 5;
                      }
                  }
              }
              for row in 0..max {
                  for col in 0..max {
                      let value = modules[row][col];
                      if value == modules[row + 1][col] && value == modules[row][col + 1] && value == modules[row + 1][col + 1] {
                          points += 3;
                      }
                  }
              }
              let finder = |cell: &dyn Fn(usize) -> bool| cell(0) && !cell(1) && cell(2) && cell(3) && cell(4) && !cell(5) && cell(6);
              for start in 0..count.saturating_sub(6) {
                  for line in 0..count {
                      if finder(&|k| modules[line][start + k]) {
                          points += 40;
                      }
                      if finder(&|k| modules[start + k][line]) {
                          points += 40;
                      }
                  }
              }
              let dark = modules.iter().map(|row| row.iter().filter(|&&m| m).count()).sum::<usize>();
              let ratio = dark as f64 / (count * count) as f64;
              let delta = (100.0 * ratio - 50.0).abs() / 5.0;
              points as f64 + delta * 10.0
          }

          // as_svg(viewbox: true, fill: :white, color: :black) over the best mask's modules.
          pub fn svg(data: &[u8]) -> Option<String> {
              let mode = mode_of(data);
              // minimum_version: the first version whose capacity is strictly greater than the bits needed.
              let version = (1..=40).find(|&v| segment_size(data, mode, v) < MAX_BITS_H[v - 1])?;
              let count = version * 4 + 17;
              let mut common: Grid = vec![vec![None; count]; count];
              probe_pattern(&mut common, 0, 0);
              probe_pattern(&mut common, count - 7, 0);
              probe_pattern(&mut common, 0, count - 7);
              adjust_pattern(&mut common, version);
              timing_pattern(&mut common);
              let codewords = create_data(data, mode, version);
              let make = |test: bool, pattern: u32| -> Vec<Vec<bool>> {
                  let mut grid = common.clone();
                  format_info(&mut grid, test, pattern);
                  if version >= 7 {
                      version_info(&mut grid, version, test);
                  }
                  map_data(&mut grid, &codewords, pattern);
                  grid.into_iter().map(|row| row.into_iter().map(|m| m.unwrap_or(false)).collect()).collect()
              };
              // get_best_mask_pattern: the first pattern with the fewest lost points.
              let mut best = (0u32, f64::MAX);
              for pattern in 0..8 {
                  let points = lost_points(&make(true, pattern));
                  if pattern == 0 || best.1 > points {
                      best = (pattern, points);
                  }
              }
              let modules = make(false, best.0);
              let size = 11;
              let dimension = modules.len() * size;
              let mut out = String::with_capacity(256 + count * count * 30);
              out.push_str(r#"<?xml version="1.0" standalone="yes"?>"#);
              out.push_str(&format!(
                  r#"<svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" xmlns:ev="http://www.w3.org/2001/xml-events" viewBox="0 0 {dimension} {dimension}" shape-rendering="crispEdges">"#
              ));
              out.push_str(&format!(r#"<rect width="{dimension}" height="{dimension}" x="0" y="0" fill="white"/>"#));
              for (row, cells) in modules.iter().enumerate() {
                  for (col, &dark) in cells.iter().enumerate() {
                      if dark {
                          let (x, y) = (col * size, row * size);
                          out.push_str(&format!(r#"<rect width="{size}" height="{size}" x="{x}" y="{y}" fill="black"/>"#));
                      }
                  }
              }
              out.push_str("</svg>");
              Some(out)
          }
      }
    RS
  end
end
