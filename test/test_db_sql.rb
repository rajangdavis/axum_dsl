# frozen_string_literal: true

# The placeholder scanner (lib/axum_dsl/db/sql.rb): it finds `:name` and the spellings the compiler refuses,
# and skips strings, quoted identifiers, comments and `::`.
#
#   ruby -Ilib test/test_db_sql.rb
require "minitest/autorun"
require "axum_dsl"

class TestDbSql < Minitest::Test
  Sql = AxumDsl::Db::Sql

  def found(sql) = Sql.placeholders(sql).map { |p| [p.kind, p.name] }

  def test_named_placeholders_in_order
    assert_equal [[:named, "limit"], [:named, "id"]], found("SELECT * FROM t WHERE id < :limit AND x = :id")
  end

  def test_the_same_name_twice_is_found_twice
    assert_equal [[:named, "a"], [:named, "a"]], found("SELECT :a, :a")
  end

  def test_offset_is_the_position_of_the_colon
    assert_equal 7, Sql.placeholders("SELECT :a").first.offset
  end

  def test_a_single_quoted_string_hides_a_placeholder
    assert_empty found("SELECT ':nope', 'it''s :nope too'")
  end

  def test_a_double_quoted_identifier_hides_a_placeholder
    assert_empty found('SELECT "col:nope" FROM t')
  end

  def test_backtick_and_bracket_identifiers_hide_a_placeholder
    assert_empty found("SELECT `a:b`, [c:d] FROM t")
  end

  def test_a_line_comment_hides_a_placeholder_until_the_end_of_the_line
    assert_equal [[:named, "yes"]], found("SELECT 1 -- :no\n, :yes")
  end

  def test_a_block_comment_hides_a_placeholder
    assert_equal [[:named, "yes"]], found("SELECT /* :no\n:nor */ :yes")
  end

  def test_an_unterminated_comment_or_string_hides_the_rest
    assert_empty found("SELECT 1 /* :no")
    assert_empty found("SELECT 'abc :no")
  end

  def test_a_double_colon_is_not_a_placeholder
    assert_empty found("SELECT x::int, y::text")
  end

  def test_a_colon_that_starts_no_name_is_not_a_placeholder
    assert_empty found("SELECT a : b, c :1")
  end

  def test_a_placeholder_right_after_an_operator
    assert_equal [[:named, "a"]], found("SELECT (:a)+1")
  end

  def test_anonymous_and_numbered_placeholders_are_reported
    assert_equal [[:anonymous, nil], [:numbered, "12"]], found("SELECT ?, ?12")
  end

  def test_dollar_and_at_placeholders_are_reported
    assert_equal [[:dollar, "name"], [:at, "other"]], found("SELECT $name, @other")
  end

  def test_a_dollar_inside_an_identifier_is_not_a_placeholder
    assert_empty found("SELECT a$b, c@d FROM t")
  end

  def test_the_text_is_not_changed
    sql = "SELECT :a -- :b\n"
    Sql.placeholders(sql)
    assert_equal "SELECT :a -- :b\n", sql
  end
end
