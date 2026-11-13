# frozen_string_literal: true

require "json"

module AxumDsl
  # `axum_dsl emit-diff`: what a change does to the generated crate, compared in memory with no cargo. The
  # "after" side is compiled from the tree on disk, or from the tree with an overlay of replacement texts
  # (`{ path => text }`, standing in for the files the way an editor's open buffers do: Lsp::Sources); the
  # "before" side is a directory a crate was emitted into earlier, or the tree on disk. Nothing is written.
  #
  # The source map is left out of the comparison (it moves with every DSL line number), and so is any line
  # that differs only in a DSL position (`models/bot.axum.rb:94`) or in a statement index (`db_run(17, ...)`). The summary names each changed unit as the
  # map does; the diff splits a line longer than LONG at statement boundaries first, so a handler that is one
  # line of thousands of characters shows the piece that changed.
  module EmitDiff
    LONG = 160
    CONTEXT = 2
    POSITION = /(\.rb):\d+/
    # The index a statement is run by (`db_run(17, "name", ...)`) counts the statements in order, so one added or removed
    # renumbers the rest.
    STATEMENT_INDEX = /\bdb_run\(\d+,/
    MAIN = "src/main.rs"

    module_function

    # The crate the tree rooted at `root` emits, { relative path => text }. `overlay` ({ path => text }, each
    # path absolute or relative to the root file's folder) replaces those files; every other file is read from
    # disk. Writes nothing.
    def compile(root, overlay = {})
      base = File.dirname(File.expand_path(root))
      table = overlay.to_h { |path, text| [File.expand_path(path, base), text] }
      Lsp::Sources.with_all(table) { Emit.files(AxumDsl.read(root), root) }
    end

    # The files of a crate emitted into `dir` earlier: those its manifest lists, or every file there.
    def read_dir(dir)
      names = Manifest.read(File.expand_path(dir)).select { |n| File.file?(File.join(dir, n)) }
      if names.empty?
        names = Dir.glob("**/*", File::FNM_DOTMATCH, base: dir).select { |n| File.file?(File.join(dir, n)) && n != Manifest::NAME }
      end
      names.to_h { |n| [n, File.binread(File.join(dir, n))] }
    end

    # The command. Returns the exit status: 0 identical, 1 different, 2 a compile or usage error.
    def run(root, against:, overlay:, summary: false, raw: false, stdin: $stdin, out: $stdout, err: $stderr)
      side = "before"
      if against
        unless File.directory?(against)
          err.puts "axum_dsl: --against #{against}: no such directory; write the crate there first with `axum_dsl #{root} -o #{against}` (no cargo)"
          return 2
        end
        before = read_dir(against)
        side = "after"
        after = compile(root)
      else
        table = JSON.parse(overlay == "-" ? stdin.read : File.read(overlay))
        unless table.is_a?(Hash) && table.all? { |k, v| k.is_a?(String) && v.is_a?(String) }
          err.puts "axum_dsl: --overlay must be a JSON object of path => full text"
          return 2
        end
        before = compile(root)
        side = "after"
        after = compile(root, table)
      end
      report(compare(before, after, split: !raw, mask: !raw), summary: summary, out: out)
    rescue CompileError => e
      err.puts "axum_dsl: emit-diff: the \"#{side}\" side does not compile:"
      err.puts e.message
      2
    rescue SystemCallError, JSON::ParserError => e
      err.puts "axum_dsl: #{e.message}"
      2
    end

    def report(result, summary:, out:)
      if result[:summary].empty?
        out.puts "emit-diff: the generated crate is identical#{" (#{masked_note(result[:masked])})" if result[:masked].positive?}"
        return 0
      end
      out.puts result[:summary]
      out.puts masked_note(result[:masked]) if result[:masked].positive?
      unless summary
        out.puts
        out.puts result[:diff]
      end
      1
    end

    def masked_note(count) = "#{count} line#{'s' unless count == 1} differ only in a DSL line number"

    # { summary: [lines], diff: [lines], masked: count } for two crates ({ path => text }).
    def compare(before, after, split: true, mask: true)
      maps = [load_map(before), load_map(after)]
      result = { summary: [], diff: [], masked: 0 }
      (before.keys | after.keys).sort.each do |name|
        next if name == CargoBuild::MAP || name == Manifest::NAME

        a = before[name]
        b = after[name]
        next if a && b && text_of(a) == text_of(b)

        rows, masked = file_rows(a ? text_of(a) : "", b ? text_of(b) : "", split, mask)
        result[:masked] += masked
        next if rows.all? { |r| r[0] == :eq }

        result[:summary].concat(a.nil? ? ["added: file #{name}"] : b.nil? ? ["removed: file #{name}"] : [])
        result[:summary].concat(summarize(name, rows, maps)) unless a.nil? || b.nil?
        result[:diff].push("--- #{a ? "a/#{name}" : '/dev/null'}", "+++ #{b ? "b/#{name}" : '/dev/null'}").concat(hunk_lines(name, rows, maps))
      end
      result
    end

    # A crate's text as a UTF-8 string, whatever bytes it holds, so a directory's files and the emitted ones compare.
    def text_of(text) = text.b.force_encoding(Encoding::UTF_8).scrub

    def load_map(files)
      JSON.parse(files[CargoBuild::MAP].to_s)["ranges"].to_a
    rescue JSON::ParserError
      []
    end

    # The map entry whose generated lines contain `line` of src/main.rs.
    def unit_at(ranges, line) = ranges.find { |r| r["from"] <= line && line <= r["to"] }

    def unit_key(range) = [range["what"], range["dsl_file"]]

    # [[tag, text, line]] for the pieces of two texts: tag :eq (text and line of the after side), :del (before
    # side) or :ins (after side); line is the 1-based line of the original file the piece came from. Also the
    # number of after lines that match only once a DSL position is masked.
    def file_rows(before, after, split, mask)
      ap, ao = pieces(before, split)
      bp, bo = pieces(after, split)
      ka = mask ? ap.map { |l| masked(l) } : ap
      kb = mask ? bp.map { |l| masked(l) } : bp
      moved = {}
      rows = myers(ka, kb).map do |tag, x, y|
        case tag
        when :eq
          moved[bo[y]] = true if ap[x] != bp[y]
          [:eq, bp[y], bo[y]]
        when :del then [:del, ap[x], ao[x]]
        else [:ins, bp[y], bo[y]]
        end
      end
      [rows, moved.size]
    end

    # A line with its DSL positions and its statement index replaced, for comparing.
    def masked(line) = line.gsub(POSITION, '\1:N').gsub(STATEMENT_INDEX, "db_run(N,")

    def pieces(text, split)
      out = []
      origin = []
      text.lines.each_with_index do |line, i|
        (split ? split_line(line.chomp) : [line.chomp]).each do |piece|
          out << piece
          origin << i + 1
        end
      end
      [out, origin]
    end

    # A line longer than `limit` cut at statement boundaries that sit outside a string literal: after `; ` and
    # ` { `, before ` }`. The pieces are indented by the braces they sit in. Not a Rust parser: a `"` opens a
    # string, a backslash escapes the next character, and the char literal '"' is skipped.
    def split_line(line, limit = LONG)
      return [line] if line.length <= limit

      indent = line[/\A */]
      pieces = []
      cur = +""
      depth = 0
      start = 0 # the brace depth where the piece being built began
      in_str = false
      flush = lambda do
        pieces << (pieces.empty? ? cur : indent + ("    " * start) + cur.lstrip) unless cur.strip.empty?
        cur = +""
      end
      add = lambda do |text|
        start = depth if cur.strip.empty? && !text.strip.empty?
        cur << text
      end
      i = 0
      while i < line.length
        c = line[i]
        if in_str
          if c == "\\"
            add.call(c + line[i + 1].to_s)
            i += 2
            next
          end
          in_str = false if c == '"'
          add.call(c)
        elsif c == "'" && line[i + 1, 2] == "\"'"
          add.call(line[i, 3])
          i += 3
          next
        elsif c == '"'
          in_str = true
          add.call(c)
        elsif c == ";" && line[i + 1] == " "
          add.call(c)
          flush.call
          i += 2
          next
        elsif c == "{"
          add.call(c)
          depth += 1
          if cur.end_with?(" {") && line[i + 1] == " "
            flush.call
            i += 2
            next
          end
        elsif c == "}"
          depth -= 1 if depth.positive?
          add.call(c)
        elsif c == " " && line[i + 1] == "}"
          flush.call
        else
          add.call(c)
        end
        i += 1
      end
      flush.call
      pieces
    end

    # Myers' O(ND) diff of two arrays of keys: [[:eq, i, j] | [:del, i, nil] | [:ins, nil, j]] in order.
    def myers(a, b)
      n = a.size
      m = b.size
      v = { 1 => 0 }
      trace = []
      (0..n + m).each do |d|
        trace << v.dup
        done = false
        (-d..d).step(2) do |k|
          x = k == -d || (k != d && v[k - 1] < v[k + 1]) ? v[k + 1] : v[k - 1] + 1
          y = x - k
          while x < n && y < m && a[x] == b[y]
            x += 1
            y += 1
          end
          v[k] = x
          if x >= n && y >= m
            done = true
            break
          end
        end
        break if done
      end
      x = n
      y = m
      ops = []
      (trace.size - 1).downto(0) do |d|
        w = trace[d]
        k = x - y
        prev_k = k == -d || (k != d && w[k - 1] < w[k + 1]) ? k + 1 : k - 1
        prev_x = w[prev_k]
        prev_y = prev_x - prev_k
        while x > prev_x && y > prev_y
          x -= 1
          y -= 1
          ops << [:eq, x, y]
        end
        next if d.zero?

        if x == prev_x
          y -= 1
          ops << [:ins, nil, y]
        else
          x -= 1
          ops << [:del, x, nil]
        end
      end
      ops.reverse
    end

    # One summary line per changed unit (named as the source map names it, from the after side's map unless the
    # unit is gone) and per run of changed lines outside every unit.
    def summarize(name, rows, maps)
      units = {}
      loose = []
      next_line = after_anchors(rows)
      rows.each_with_index do |(tag, _text, line), i|
        next if tag == :eq

        range = name == MAIN ? unit_at(maps[tag == :del ? 0 : 1], line) : nil
        if range
          units[unit_key(range)] ||= [tag == :del ? :before : :after, range]
        else
          loose << (tag == :del ? next_line[i] : line)
        end
      end
      kept = { before: maps[0].map { |r| unit_key(r) }, after: maps[1].map { |r| unit_key(r) } }
      listed = units.map do |key, (_side, range)|
        kind = kept[:before].include?(key) && kept[:after].include?(key) ? "changed" : (kept[:after].include?(key) ? "added" : "removed")
        [kind, range]
      end
      lines = unit_lines(listed)
      lines + runs(loose.sort.uniq).map { |a, b| "changed: (unmapped) #{name} #{a == b ? "line #{a}" : "lines #{a}-#{b}"}" }
    end

    # The summary line of each unit. A unit removed from one DSL file and added to another under the same name is one
    # line, `moved: execute `x` (old_file:line -> new_file:line)`; the diff still shows its text if that changed.
    def unit_lines(listed)
      place = ->(r) { "#{r['dsl_file'] || '?'}:#{r['dsl_line']}" }
      twins = {}
      listed.each do |kind, range|
        next unless kind == "removed"

        twin = listed.find { |k, r| k == "added" && r["what"] == range["what"] && !twins.value?(r) }
        twins[range] = twin[1] if twin
      end
      listed.filter_map do |kind, range|
        if twins.key?(range) then "moved: #{range['what']} (#{place.call(range)} -> #{place.call(twins[range])})"
        elsif !twins.value?(range) then "#{kind}: #{range['what']} (#{place.call(range)})"
        end
      end
    end

    # For each row, the after-side line a deletion sits before (the next row that is not a deletion).
    def after_anchors(rows)
      anchors = Array.new(rows.size)
      nxt = rows.reverse_each.find { |r| r[0] != :del }&.then { |r| r[2] } || 1
      (rows.size - 1).downto(0) do |i|
        nxt = rows[i][2] unless rows[i][0] == :del
        anchors[i] = nxt
      end
      anchors
    end

    def runs(lines)
      lines.each_with_object([]) do |l, out|
        out.last && l <= out.last[1] + 1 ? out.last[1] = l : out << [l, l]
      end
    end

    # The unified diff of `rows`: hunks of changed rows with CONTEXT rows around them, each headed with the units
    # it touches. Line numbers count the pieces after splitting.
    def hunk_lines(name, rows, maps)
      a_at = []
      b_at = []
      a = 0
      b = 0
      rows.each do |tag, _, _|
        a_at << a
        b_at << b
        a += 1 unless tag == :ins
        b += 1 unless tag == :del
      end
      ranges = []
      rows.each_index do |i|
        next if rows[i][0] == :eq

        lo = [i - CONTEXT, 0].max
        hi = [i + CONTEXT, rows.size - 1].min
        ranges.last && lo <= ranges.last[1] + 1 ? ranges.last[1] = hi : ranges << [lo, hi]
      end
      ranges.flat_map do |lo, hi|
        slice = rows[lo..hi]
        labels = slice.filter_map do |tag, _, line|
          next if tag == :eq || name != MAIN

          unit_at(maps[tag == :del ? 0 : 1], line)&.fetch("what")
        end.uniq
        head = "@@ -#{a_at[lo] + 1},#{slice.count { |r| r[0] != :ins }} +#{b_at[lo] + 1},#{slice.count { |r| r[0] != :del }} @@"
        [labels.empty? ? head : "#{head} #{labels.join(', ')}"] +
          slice.map { |tag, text, _| "#{{ eq: ' ', del: '-', ins: '+' }[tag]}#{text}" }
      end
    end
  end
end
