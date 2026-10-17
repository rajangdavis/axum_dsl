# frozen_string_literal: true

# The Ruby-side Rust::Int32 / Rust::Int64: Rust semantics under plain Ruby. These are the
# behaviours the compiler must reproduce (and test/e2e_arith.sh checks against the real server).
#
#   ruby -Ilib test/test_rust_int.rb
require "minitest/autorun"
require "rust"

class TestRustInt < Minitest::Test
  def i32(n) = Rust.Int32(n)

  def test_division_truncates_toward_zero
    { [-7, 2] => -3, [7, 2] => 3, [7, -2] => -3, [-7, -2] => 3, [6, 3] => 2, [0, 5] => 0 }.each do |(a, b), want|
      assert_equal want, (i32(a) / i32(b)).to_i, "#{a} / #{b}"
    end
  end

  def test_remainder_takes_the_sign_of_the_dividend
    { [-7, 3] => -1, [7, -3] => 1, [-7, -3] => -1, [7, 3] => 1, [6, 3] => 0 }.each do |(a, b), want|
      assert_equal want, (i32(a) % i32(b)).to_i, "#{a} % #{b}"
    end
  end

  def test_ruby_rounds_down_where_rust_truncates
    assert_equal(-4, -7 / 2)
    assert_equal(2, -7 % 3)
    assert_equal(-3, (i32(-7) / 2).to_i)
    assert_equal(-1, (i32(-7) % 3).to_i)
  end

  def test_mixing_with_a_plain_integer_keeps_rust_semantics
    assert_instance_of Rust::Int32, i32(-7) / 2
    assert_instance_of Rust::Int32, i32(7) + 1
  end

  def test_overflow_raises
    assert_raises(RangeError) { i32(2_147_483_647) + 1 }
    assert_raises(RangeError) { i32(65_536) * 65_536 }
    assert_raises(RangeError) { -i32(-2_147_483_648) }
    assert_raises(RangeError) { i32(-2_147_483_648) / -1 }
    assert_raises(RangeError) { Rust.Int32(2_147_483_648) }
    assert_equal 9_223_372_036_854_775_807, Rust.Int64(9_223_372_036_854_775_806).+(1).to_i
    assert_raises(RangeError) { Rust.Int64(9_223_372_036_854_775_807) + 1 }
  end

  def test_division_by_zero_raises
    assert_raises(ZeroDivisionError) { i32(1) / 0 }
    assert_raises(ZeroDivisionError) { i32(1) % 0 }
  end

  def test_comparison_and_conversion
    assert i32(3) < i32(4)
    assert_equal i32(3), 3
    assert_equal "5", i32(5).to_s
    assert_raises(TypeError) { Rust.Int32("5") }
  end
end
