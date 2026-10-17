# frozen_string_literal: true

module Rust
  # Integers that behave the way Rust's do: `/` and `%` truncate toward zero, and a result that
  # does not fit the type raises RangeError (the compiled server reports an overflow error).
  # Ruby does not allow subclassing Integer, so these wrap one. Mixing with a plain Integer is
  # allowed; the result is a Rust integer (Rust semantics are sticky). See DESIGN.md.
  class Int
    include Comparable

    attr_reader :value

    def initialize(value)
      value = value.value if value.is_a?(Int)
      raise TypeError, "#{self.class.name} wants an Integer, got #{value.class}" unless value.is_a?(Integer)
      raise RangeError, "#{value} does not fit in #{self.class::TYPE} (#{self.class::MIN}..=#{self.class::MAX})" unless value.between?(self.class::MIN, self.class::MAX)

      @value = value
    end

    def +(other) = self.class.new(@value + operand(other))
    def -(other) = self.class.new(@value - operand(other))
    def *(other) = self.class.new(@value * operand(other))
    def -@ = self.class.new(-@value)

    # Truncating division (Rust): -7 / 2 == -3.
    def /(other)
      divisor = operand(other)
      raise ZeroDivisionError, "division by zero" if divisor.zero?

      quotient = @value.abs / divisor.abs
      self.class.new((@value.negative? ^ divisor.negative?) ? -quotient : quotient)
    end

    # Remainder with the sign of the dividend (Rust): -7 % 3 == -1.
    def %(other)
      divisor = operand(other)
      raise ZeroDivisionError, "division by zero" if divisor.zero?

      self.class.new(@value - (divisor * (self / divisor).value))
    end

    def <=>(other) = @value <=> operand(other)
    def ==(other) = other.is_a?(Int) || other.is_a?(Integer) ? @value == operand(other) : false
    def to_i = @value
    def to_s = @value.to_s
    def inspect = "#{self.class.name.split('::').last}(#{@value})"

    private

    def operand(other) = other.is_a?(Int) ? other.value : other
  end

  class Int32 < Int
    TYPE = "i32"
    MIN = -(2**31)
    MAX = (2**31) - 1
  end

  class Int64 < Int
    TYPE = "i64"
    MIN = -(2**63)
    MAX = (2**63) - 1
  end

  # Rust.Int32(x) reads like the Integer(x) conversion function.
  def self.Int32(value) = Int32.new(value)
  def self.Int64(value) = Int64.new(value)
end
