# frozen_string_literal: true

module AxumDsl
  # "Did you mean" support for compile errors: the nearest known names to a misspelt one.
  module Suggest
    module_function

    # Levenshtein edit distance between two strings.
    def distance(a, b)
      prev = (0..b.size).to_a
      a.each_char.with_index(1) do |ca, i|
        cur = [i]
        b.each_char.with_index(1) do |cb, j|
          cur << [prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca == cb ? 0 : 1)].min
        end
        prev = cur
      end
      prev.last
    end

    # Up to `limit` candidates close to `word`, nearest first; ties break alphabetically. A candidate is
    # close when its distance is at most a third of the longer word (at least 1, at most 3), or when one
    # contains the other and both are 4+ characters long.
    def nearest_n(word, candidates, limit = 3)
      w = word.to_s
      scored = candidates.map(&:to_s).uniq.filter_map do |c|
        next if c == w

        d = distance(w.downcase, c.downcase)
        max = [[[w.size, c.size].max / 3, 1].max, 3].min
        contained = [w.size, c.size].min >= 4 && (c.include?(w) || w.include?(c))
        [d, c] if d <= max || contained
      end
      scored.sort.first(limit).map(&:last)
    end

    # The single nearest candidate, or nil when nothing is close (same rules as nearest_n).
    def nearest(word, candidates) = nearest_n(word, candidates, 1).first
  end
end
