# frozen_string_literal: true

module AxumDsl
  module Db
    # Reads the SQL a `query` or `execute` carries for its placeholders, and nothing else: the text is never
    # rewritten, because the SQL the user wrote is what runs, byte for byte. A placeholder is `:name` (SQLite
    # binds it by name, so the emitted statement is the user's own). The scanner skips what is not code: a
    # 'string', a "quoted identifier" (also `quoted` and [bracketed], which SQLite accepts), a -- comment to the
    # end of the line and a /* comment */. `::` is not a placeholder. The other SQLite placeholder spellings
    # (`?`, `?NNN`, `$name`, `@name`) are found too, so the reader can refuse them with the message that says
    # to write `:name`.
    module Sql
      # kind is :named, :anonymous (`?`), :numbered (`?12`), :dollar (`$name`) or :at (`@name`); name is the
      # text after the sigil (nil for `?`); offset is the 0-based character position of the sigil.
      Placeholder = Struct.new(:kind, :name, :offset)

      WORD = /[A-Za-z0-9_]/
      WORD_START = /[A-Za-z_]/
      CLOSERS = { "'" => "'", '"' => '"', "`" => "`", "[" => "]" }.freeze

      module_function

      def placeholders(sql)
        out = []
        i = 0
        size = sql.length
        while i < size
          c = sql[i]
          nxt = sql[i + 1]
          if CLOSERS.key?(c)
            close = sql.index(CLOSERS.fetch(c), i + 1)
            i = close ? close + 1 : size
          elsif c == "-" && nxt == "-"
            i = sql.index("\n", i) || size
          elsif c == "/" && nxt == "*"
            close = sql.index("*/", i + 2)
            i = close ? close + 2 : size
          elsif c == ":" && nxt == ":"
            i += 2
          elsif c == ":" && nxt&.match?(WORD_START)
            i = take(sql, i, :named, out)
          elsif c == "?"
            j = i + 1
            j += 1 while j < size && sql[j].match?(/[0-9]/)
            out << Placeholder.new(j > i + 1 ? :numbered : :anonymous, j > i + 1 ? sql[(i + 1)...j] : nil, i)
            i = j
          elsif (c == "$" || c == "@") && nxt&.match?(WORD_START) && !(i.positive? && sql[i - 1].match?(WORD))
            i = take(sql, i, c == "$" ? :dollar : :at, out)
          else
            i += 1
          end
        end
        out
      end

      # The placeholder name that starts after the sigil at i; returns the position after it.
      def take(sql, i, kind, out)
        j = i + 1
        j += 1 while j < sql.length && sql[j].match?(WORD)
        out << Placeholder.new(kind, sql[(i + 1)...j], i)
        j
      end
    end
  end
end
