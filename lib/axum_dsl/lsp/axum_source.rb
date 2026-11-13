# frozen_string_literal: true

module AxumDsl
  module Lsp
    # What the language server has to know about axum_dsl's own project shape, in small functions so the
    # dialect-neutral parts (Root, Spans, Position) never mention it: which files may be a root and how they
    # include others, what a statement (`query` / `execute`) is and how the compiler rendered it, where a
    # `render` finds its view, which compiler entry declares a name.
    module AxumSource
      GLOB = "*.axum.rb"
      USE_DSL = /^[ \t]*use_dsl[ \t(]*"([^"]+)"/

      module_function

      # The relative paths a DSL text splices in with `use_dsl`.
      def includes(text) = text.scan(USE_DSL).flatten

      # May this text be built on its own? A file whose one top-level call is `fragment`, `model` or
      # `controller` is spliced in by another file and is not a root.
      def root?(text)
        top = Prism.parse(text).value.statements.body.first
        !(top.is_a?(Prism::CallNode) && Reader::FILE_KINDS.include?(top.name))
      end

      # name => the IR entry of every `query` and `execute` the compile read.
      def statements(ir) = ir ? ir["queries"].to_a.to_h { |q| [q["name"], q] } : {}

      # The hover of a statement: its kind, arguments, result, where it is declared and the SQL that runs,
      # exactly as the compiler holds it (a relation block's SQL is the one the compiler rendered; a `destroy`
      # lists its statements in the order they run).
      def statement_markdown(query)
        lines = ["**`#{query['name']}`** - #{query['kind']}", ""]
        lines << "- args: #{args_text(query['args'])}"
        lines << "- returns: #{returns_text(query)}"
        lines << "- declared at `#{query['at']}`"
        lines << ""
        sqls = query["sqls"]
        if sqls
          lines << "SQL, #{sqls.size} statements run in this order as one unit:"
          sqls.each_with_index { |sql, i| lines.push("", "#{i + 1}.", "```sql", sql, "```") }
        else
          lines.push("```sql", query["sql"].to_s, "```")
        end
        lines.join("\n")
      end

      def args_text(args)
        pairs = args.to_a
        pairs.empty? ? "none" : "`#{pairs.map { |name, type| "#{name}: #{type}" }.join(', ')}`"
      end

      def returns_text(query)
        return "`#{query['rtype']}` (rows changed)" if query["shape"] == "execute"

        # The reader folds `returns:` into the entry (shape, record or type, nilable) once the records are known.
        text =
          case query["shape"]
          when "one" then ":#{query['record']}?"
          when "list" then "list(:#{query['record']})"
          else ":#{query['type']}#{'?' if query['nilable']}"
          end
        "`#{text}`"
      end

      # The `declaration` entry the compiler recorded for `call` (one of `calls`) named `name`, as a span of the
      # name token in the file that declares it (see Reader#note_declaration), or nil.
      def declaration(entries, calls, name)
        found = entries.find { |e| e[:kind] == "declaration" && calls.include?(e[:call]) && e[:name].to_s == name.to_s }
        found && declared_span(found)
      end

      # The `current` whose `reader:` is `name` (`current :user, reader: :current_user`).
      def reader_declaration(entries, name)
        found = entries.find { |e| e[:kind] == "declaration" && e[:call] == "current" && e.dig(:keywords, "reader") == name.to_s }
        found && declared_span(found)
      end

      def declared_span(entry)
        { file: entry[:file], line: entry[:name_line] || entry[:line], col: entry[:name_col] || entry[:col],
          end_line: entry[:name_line] || entry[:end_line], end_col: entry[:name_end_col] || entry[:end_col] }
      end

      # The file `render :name` reads, or nil when there is none: the views folder (`set :views`, else the
      # default) beside the root file.
      def view_file(ir, root_path, name)
        dir = (ir && ir["views"]) || Views::DEFAULT_DIR
        rel = Views.rel(name, dir, bad: ->(message) { raise ArgumentError, message })
        return nil if rel.nil?

        real = File.expand_path(rel, Views.folder(root_path))
        real if File.file?(real) || Sources[real]
      rescue ArgumentError, SystemCallError
        nil
      end
    end
  end
end
