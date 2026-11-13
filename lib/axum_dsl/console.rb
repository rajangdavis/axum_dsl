# frozen_string_literal: true

require "json"
require "open3"
require "prism"

module AxumDsl
  # The typed Rails-console equivalent (docs/console.md): `axum_dsl console FILE.rb` compiles the app, starts the
  # emitted binary in its `--console` mode (console_rust.rb) and reads lines. A line names a declared query and gives
  # literal arguments; the compiler's declarations check the name and every argument's type BEFORE anything is sent,
  # and the binary decodes the answer at run time. Nothing here is checked by rustc. This file and console_rust.rb
  # depend on nothing else in the compiler but the IR, `Suggest` and (for .why/.impact) `TypeGraph`, so both can move
  # into the later framework extraction.
  module Console
    # A line the console will not run; the message is shown as it is.
    class Refused < StandardError; end

    BANNER = "read-only; lines are typed by the axum_dsl compiler and decoded at run time, not checked by rustc"
    PAGE = 20
    CELL = 40

    Query = Struct.new(:name, :kind, :args, :shape, :record, :fields, :type, :nilable, :sql, keyword_init: true) do
      def write? = shape == "execute" || kind == "execute"

      # `recent_notes(limit: i64)`
      def signature = "#{name}(#{args.map { |n, t| "#{n}: #{t}" }.join(', ')})"

      # The declared row type: `[{id: i64, tag: string?}]`, `{id: i64}?`, `i64?`, or the count an execute answers.
      def row_type
        fields_text = "{#{fields.map { |f| "#{f[:name]}: #{f[:type]}#{'?' if f[:optional]}" }.join(', ')}}" if fields
        case shape
        when "list" then "[#{fields_text}]"
        when "one" then "#{fields_text}?"
        when "scalar" then "#{type}#{'?' if nilable}"
        else "i64 (rows changed)"
        end
      end
    end

    # What the compiler declared: the queries (name, typed args, row type, SQL) and the tables.
    class Catalog
      attr_reader :queries, :tables

      def initialize(ir)
        records = ir["records"].to_a.to_h { |r| [r["name"], r] }
        @queries = ir["queries"].to_a.map do |q|
          rec = records[q["record"]]
          fields = rec && rec["fields"].reject { |f| f["from"] }.map { |f| { name: f["name"], type: f["type"], optional: f["optional"] == true } }
          Query.new(name: q["name"], kind: q["kind"], args: q["args"].to_h, shape: q["shape"], record: q["record"], fields: fields,
                    type: q["type"], nilable: q["nilable"], sql: q["sqls"] ? q["sqls"].join(";\n") : q["sql"])
        end
        @tables = ir["tables"].to_a.to_h { |t| [t["name"], t["columns"]] }
      end

      def query(name) = @queries.find { |q| q.name == name.to_s }

      def names = @queries.map(&:name)

      # The query `name` with `args` checked against its declaration, or a Refused that says what is wrong and,
      # for a misspelt name, which declared name was meant.
      def check(name, args)
        q = query(name) or raise Refused, unknown(name, "query", names)
        raise Refused, "`#{q.name}` is an execute: it writes, and the console is read-only (writes need --write, not built yet)" if q.write?

        args.each_key do |key|
          next if q.args.key?(key)

          raise Refused, "#{unknown(key, 'argument', q.args.keys, "`#{q.name}` takes no argument `#{key}`")}; it takes #{takes(q)}"
        end
        q.args.each do |arg, type|
          raise Refused, "`#{q.name}` needs `#{arg}: #{type}`" unless args.key?(arg)
          raise Refused, "argument `#{arg}` of `#{q.name}` is #{type}, got #{args[arg].inspect} (#{ruby_class(args[arg])})" unless fits?(type, args[arg])
        end
        q
      end

      def unknown(word, what, candidates, message = "no #{what} `#{word}`")
        near = Suggest.nearest_n(word, candidates)
        near.empty? ? message : "#{message}; did you mean #{near.map { |n| "`#{n}`" }.join(' or ')}?"
      end

      def takes(q) = q.args.empty? ? "no arguments" : q.args.map { |n, t| "#{n}: #{t}" }.join(", ")

      # The declared scalar types: an f64 also takes an integer literal; a time is its text.
      def fits?(type, value)
        case type
        when "i64" then value.is_a?(Integer) && value.bit_length < 64
        when "f64" then value.is_a?(Float) || value.is_a?(Integer)
        when "string", "time" then value.is_a?(String)
        when "bool" then value == true || value == false
        else true
        end
      end

      def ruby_class(value) = value.nil? ? "nil" : value.class.name
    end

    # A console line as a call: `name(arg: value, ...)`, `name arg: value` or `q :name, arg: value`. Values are
    # literals only (numbers, strings, true, false, nil); the line is parsed, never evaluated.
    module Line
      module_function

      # [name, {arg => value}]
      def parse(text)
        result = Prism.parse(text)
        raise Refused, "cannot read that line: #{result.errors.first.message}" unless result.success?

        body = result.value.statements.body
        call = body.first
        unless body.size == 1 && call.is_a?(Prism::CallNode) && call.receiver.nil? && call.block.nil?
          raise Refused, "a line is `name(arg: value, ...)` or `q :name, arg: value` (.help lists the other commands)"
        end

        given = (call.arguments&.arguments || []).dup
        if call.name == :q
          head = given.shift
          raise Refused, "`q` takes the query name first: q :name, arg: value" unless head.is_a?(Prism::SymbolNode) || head.is_a?(Prism::StringNode)

          name = head.unescaped
        else
          name = call.name.to_s
        end
        [name, arguments(given)]
      end

      def arguments(given)
        return {} if given.empty?

        hash = given.first
        unless given.size == 1 && hash.respond_to?(:elements) && hash.elements.all?(Prism::AssocNode)
          raise Refused, "arguments are keywords: name(arg: value, ...)"
        end

        hash.elements.to_h do |pair|
          raise Refused, "an argument name is a plain keyword (limit: 5)" unless pair.key.is_a?(Prism::SymbolNode)

          [pair.key.unescaped, literal(pair.value)]
        end
      end

      def literal(node)
        case node
        when Prism::IntegerNode, Prism::FloatNode then node.value
        when Prism::StringNode then node.unescaped
        when Prism::TrueNode then true
        when Prism::FalseNode then false
        when Prism::NilNode then nil
        else raise Refused, "an argument is a literal (a number, a string, true, false or nil), not `#{node.slice}`"
        end
      end
    end

    # An aligned text table; numbers right-aligned, a long cell cut at CELL characters.
    module Table
      module_function

      def cell(value)
        text = value.nil? ? "NULL" : value.to_s.gsub(/\s+/, " ")
        text.size > CELL ? "#{text[0, CELL - 1]}…" : text
      end

      def render(columns, rows)
        cells = rows.map { |r| r.map { |v| cell(v) } }
        widths = columns.each_index.map { |i| [columns[i].size, *cells.map { |r| r[i].size }].max }
        line = ->(texts, numeric) { texts.each_with_index.map { |t, i| numeric[i] ? t.rjust(widths[i]) : t.ljust(widths[i]) }.join("  ").rstrip }
        right = columns.each_index.map { |i| rows.any? && rows.all? { |r| r[i].nil? || r[i].is_a?(Numeric) } }
        [line.call(columns, Array.new(columns.size, false)), widths.map { |w| "-" * w }.join("  "),
         *cells.map { |r| line.call(r, right) }]
      end
    end

    # The running binary: one JSON request line out, one response line back.
    class Child
      def initialize(binary, db)
        @stdin, @stdout, @stderr, @wait = Open3.popen3(binary, "--console", db)
        ready = @stdout.gets
        return if ready

        message = @stderr.read.to_s.strip
        close
        raise Refused, message.empty? ? "the console process ended before it was ready" : message
      end

      # The parsed response: {"columns", "rows", "ms"} or {"error"}.
      def call(stmt, args)
        @stdin.puts(JSON.generate("stmt" => stmt, "args" => args))
        @stdin.flush
        line = @stdout.gets or raise Refused, "the console process ended: #{@stderr.read.to_s.strip}"
        JSON.parse(line)
      rescue Errno::EPIPE
        raise Refused, "the console process ended: #{@stderr.read.to_s.strip}"
      end

      def close
        @stdin.close unless @stdin.closed?
        @wait.value
      end
    end

    # The line loop. `child` answers `call(stmt, args)`; `graph` is a TypeGraph (or nil); everything is written to `out`.
    class Repl
      def initialize(catalog, child:, graph: nil, out: $stdout)
        @catalog = catalog
        @child = child
        @graph = graph
        @out = out
        @last = nil
      end

      # Runs one line; false when it asked to quit.
      def handle(text)
        text = text.strip
        return true if text.empty?
        return meta(text) if text.start_with?(".")

        run(text)
        true
      rescue Refused => e
        @out.puts "error: #{e.message}"
        true
      end

      def banner
        @out.puts "axum_dsl console: #{BANNER}"
        @out.puts "#{@catalog.queries.count { |q| !q.write? }} queries (.queries lists them, .help the commands)"
      end

      private

      def run(text)
        name, args = Line.parse(text)
        q = @catalog.check(name, args)
        @out.puts q.sql.to_s.strip, "=> #{q.row_type}"
        reply = @child.call(q.name, args)
        raise Refused, reply["error"] if reply["error"]

        @last = { columns: reply["columns"], rows: reply["rows"], ms: reply["ms"], shown: 0 }
        show(@last)
      end

      def show(last)
        slice = last[:rows][last[:shown], PAGE] || []
        @out.puts Table.render(last[:columns], slice) unless last[:columns].empty?
        last[:shown] += slice.size
        total = last[:rows].size
        more = total > last[:shown] ? " (#{total - last[:shown]} more: .more)" : ""
        @out.puts "#{total} #{total == 1 ? 'row' : 'rows'}, #{last[:ms]} ms#{more}"
      end

      def meta(text)
        word, rest = text.split(/\s+/, 2)
        rest = rest.to_s.strip
        case word
        when ".quit", ".exit" then return false
        when ".help" then help
        when ".queries" then @catalog.queries.each { |q| @out.puts "#{q.signature} -> #{q.row_type}#{'  (write: not available here)' if q.write?}" }
        when ".more" then more
        when ".sql" then sql(rest)
        when ".schema" then schema(rest)
        when ".why", ".impact" then graph(word.delete_prefix("."), rest)
        else @out.puts "error: unknown command #{word}; .help lists them"
        end
        true
      end

      def help
        @out.puts <<~HELP
          name(arg: value, ...)   run a declared query; also `q :name, arg: value`. Arguments are literals.
          .queries                the declared queries, their arguments and row types
          .sql NAME               a query's SQL, without running it
          .schema [TABLE]         a declared table's columns (no TABLE: the tables)
          .why NODE               how a type derives (type graph), e.g. field:Note.id
          .impact NODE            what takes its type from NODE, e.g. column:notes.id
          .more                   the next #{PAGE} rows of the last result
          .quit                   leave
        HELP
      end

      def more
        return @out.puts("error: nothing to continue; run a query first") unless @last
        return @out.puts("error: that was the last row") if @last[:shown] >= @last[:rows].size

        show(@last)
      end

      def sql(name)
        q = @catalog.query(name)
        @out.puts(q ? q.sql.to_s.strip : "error: #{@catalog.unknown(name, 'query', @catalog.names)}")
      end

      def schema(table)
        tables = @catalog.tables
        return @out.puts(tables.empty? ? "no table is declared in the DSL file" : tables.keys.join("\n")) if table.empty?

        columns = tables[table]
        return @out.puts("error: #{@catalog.unknown(table, 'table', tables.keys)}") unless columns

        @out.puts Table.render(%w[column type], columns.map { |c| [c["name"], "#{c['type']}#{'?' if c['optional']}"] })
      end

      def graph(kind, node)
        return @out.puts("error: the type graph is not available") unless @graph
        return @out.puts("error: .#{kind} needs a node, e.g. column:notes.id") if node.empty?

        @out.puts @graph.report(kind.to_sym => node)
      rescue TypeGraph::UnknownNode => e
        @out.puts "error: #{e.message}"
      end
    end

    module_function

    # The binary the crate in `out` builds, or nil when cargo's target dir is not where it is expected.
    def binary(ir, out)
      File.join(ENV.fetch("CARGO_TARGET_DIR", File.join(out, "target")), "debug", ir["name"])
    end

    # Newer than every file of the crate: cargo would have nothing to do.
    def fresh?(bin, out)
      return false unless File.file?(bin)

      inputs = [File.join(out, "Cargo.toml"), File.join(out, "Cargo.lock"), *Dir.glob(File.join(out, "src", "**", "*"))].select { |f| File.file?(f) }
      inputs.all? { |f| File.mtime(f) <= File.mtime(bin) }
    end

    # The database the console opens: --db, else the variable the app's `database` names when set, else its path
    # (relative to the crate dir, as `axum_dsl run` runs the server there).
    def database_path(ir, out, db)
      return File.expand_path(db) if db

      env = ir["database"]["env"]
      return ENV[env] if env && !ENV[env].to_s.empty?

      File.expand_path(ir["database"]["path"], out)
    end

    # The whole command: build when needed, start the binary, loop on `input`. Returns the exit status.
    def run(ir, out:, db: nil, locked: true, graph: nil, input: $stdin, io: $stdout)
      bin = binary(ir, out)
      return 1 unless fresh?(bin, out) || CargoBuild.run(out, locked: locked)

      child = Child.new(bin, database_path(ir, out, db))
      repl = Repl.new(Catalog.new(ir), child: child, graph: graph, out: io)
      repl.banner
      loop do
        io.print "console> "
        io.flush
        line = input.gets or break
        break unless repl.handle(line)
      end
      child.close
      0
    rescue Refused => e
      warn "axum_dsl console: #{e.message}"
      2
    end
  end
end
