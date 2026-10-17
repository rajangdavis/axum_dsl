# frozen_string_literal: true

# The Unicode regex forms Campfire uses that the translator accepts (lib/axum_dsl/regex_translate.rb),
# with the exact Rust source each one emits, and the forms it still refuses.
#
#   ruby -Ilib test/test_regex_translate.rb
require "minitest/autorun"
require "axum_dsl"

class TestRegexTranslate < Minitest::Test
  T = AxumDsl::RegexTranslate

  def test_word_posix_class_in_a_negated_class
    assert_equal '(?m)[^\p{Alphabetic}\p{M}\p{Nd}\p{Pc}]', T.translate('[^[:word:]]')
  end

  def test_word_posix_class_alone_in_a_class
    assert_equal '(?m)[\p{Alphabetic}\p{M}\p{Nd}\p{Pc}]+', T.translate('[[:word:]]+')
  end

  def test_word_posix_class_beside_other_members
    assert_equal '(?m)[\p{Alphabetic}\p{M}\p{Nd}\p{Pc}-]', T.translate('[[:word:]-]')
  end

  def test_space_property_is_white_space
    assert_equal '(?m)\A\p{White_Space}+|\p{White_Space}+\z', T.translate('\A\p{Space}+|\p{Space}+\z')
  end

  def test_emoji_presentation_property
    assert_equal '(?m)\p{Emoji_Presentation}', T.translate('\p{Emoji_Presentation}')
  end

  def test_extended_pictographic_property
    assert_equal '(?m)\p{Extended_Pictographic}', T.translate('\p{Extended_Pictographic}')
  end

  def test_campfire_emoji_pattern
    assert_equal '(?m)\A(\p{Emoji_Presentation}|\p{Extended_Pictographic}|\x{FE0F})+\z',
                 T.translate('\A(\p{Emoji_Presentation}|\p{Extended_Pictographic}|\uFE0F)+\z')
  end

  def test_unicode_escape_is_a_rust_hex_escape
    assert_equal '(?m)\x{FE0F}', T.translate('\uFE0F')
  end

  def test_an_unknown_posix_class_is_refused_and_named
    error = assert_raises(T::Unsupported) { T.translate('[[:digit:]]') }
    assert_match(/\[:digit:\]/, error.message)
  end

  def test_a_negated_posix_class_is_refused
    assert_raises(T::Unsupported) { T.translate('[[:^word:]]') }
  end

  def test_an_unknown_property_is_refused_and_named
    error = assert_raises(T::Unsupported) { T.translate('\p{Foo}') }
    assert_match(/Foo/, error.message)
  end
end
