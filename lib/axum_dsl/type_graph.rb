# frozen_string_literal: true

require "json"
require "tsort"

module AxumDsl
  # How the types of a compile interact: a graph of the things that carry a type (a column, a named expr, a record field,
  # an association, a statement, a route's parameter) and the one relation between them, "takes its type from". An edge
  # `to <- from` says `to` got its type (or its existence) from `from`, with the rule that did it (`select`, `widen
  # bool->i64`, `has_one_attached`, ...). Nodes are `kind:qualified.name` ids: `column:rooms.id`, `expr:is_current`,
  # `field:RoomRow.id`, `assoc:User.avatar_attachment`, `query:attach_user_avatar`.
  #
  # Like TypeNames::Collector it is opt-in: AxumDsl.read(path, graph: TypeGraph.new) fills it while the compiler derives
  # things (`graph&.derive`), and a compile without one (build, check) is untouched. It answers questions - `why` a node
  # has its type, what `impact` a change to one has - and renders them as text; the CLI (`axum_dsl graph`) and the
  # language server call the same functions, so a later virtual document is one more caller.
  class TypeGraph
    include TSort

    # The places the reader registers what it derives (`@graph&.derive`), kept together so the reader files change by a call
    # each. Included in Reader; every method is a no-op without a graph. They read the provenance the derivations already
    # store as data ("derived" => { "from" =>, "at" => }) and never re-derive it.
    module Sites
      private

      # `has_one_attached :avatar` of a model: the declaration, and the two associations it derives.
      def graph_attached_associations(model, name, derived)
        return unless @graph

        src = "attached:#{model}.#{name}"
        @graph.declare(src, at: derived["at"])
        %W[#{name}_attachment #{name}_blob].each { |assoc| @graph.derive("assoc:#{model}.#{assoc}", from: [src], rule: "has_one_attached", at: derived["at"]) }
      end

      # One statement `attach` runs (role: insert, detach, attach, touch), derived from the same declaration.
      def graph_attached_statement(model, name, statement, role, derived)
        @graph&.derive("query:#{statement}", from: ["attached:#{model}.#{name}"], rule: "has_one_attached #{role}", at: derived["at"])
      end

      # The fields of the record a relation returns take their types from what the relation selects: each column or
      # expr (`sources`, field name => ids kept by Db::Rel), by `select`; or by `widen bool->i64` where a declared i64 field takes a bool.
      def graph_record_fields(srv, node, record, fields, sources)
        return unless @graph

        declared = srv["records"].find { |r| r["name"] == record }&.fetch("fields", []) || []
        fields.each do |f|
          want = declared.find { |d| d["name"] == f[:name] }
          widen = want && f[:type].to_s == "bool" && want["type"] == "i64"
          type = "#{want ? want["type"] : f[:type]}#{"?" if f[:optional]}"
          @graph.derive("field:#{record}.#{f[:name]}", from: Array(sources && sources[f[:name]]), rule: widen ? "widen bool->i64" : "select", at: node.message_loc || node, type: type)
        end
      end

      # The hook for a path parameter derived from a column (`resources :rooms`): a param field that carries
      # "derived" => { "from" => "rooms.id", "via" =>, "at" => } takes its type from that table column, by the rule `via`
      # names. The reader calls it for each member route of a resource, with the route's DSL path (`GET /rooms/:id`).
      def graph_path_param(route, field, node)
        d = field["derived"]
        return unless @graph && d

        src = "column:#{d["from"]}"
        @graph.declare(src, at: d["at"])
        @graph.derive("param:#{route}.#{field["name"]}", from: [src], rule: d["via"] || "path param", at: node, type: field["type"].to_s)
      end
    end

    # origin is :declared (written in the DSL) or :derived (the compiler made it from other nodes). The span is the
    # place to show for it: file (absolute, as TypeNames::Collector keeps it) and line/col, or nil for a node with no place.
    Node = Struct.new(:id, :kind, :origin, :type, :file, :line, :col, :end_line, :end_col, keyword_init: true) do
      def located? = !file.nil? && !line.nil?
      def place = located? ? "#{file}:#{line}" : nil
    end
    Edge = Struct.new(:to, :from, :rule, :file, :line, :col, :end_line, :end_col, keyword_init: true)

    attr_reader :nodes, :edges

    def initialize
      @nodes = {}
      @edges = []
    end

    # A node written in the DSL (a column, an expr, a `has_one_attached`). `at` is a Prism node or location, a
    # "FILE:LINE" string (what the compiler stores as data, e.g. in a "derived" hash), or nil.
    def declare(id, at: nil, type: nil)
      put(id, :declared, at, type)
    end

    # `id` takes its type from each of `from` (node ids) by `rule`. A source not seen yet is a placeholder node with no
    # place; deriving the same node again adds edges.
    def derive(id, from:, rule:, at: nil, type: nil)
      put(id, :derived, at, type)
      span = span_of(at)
      Array(from).uniq.each do |src|
        @nodes[src] ||= Node.new(id: src, kind: kind_of(src), origin: :declared)
        next if @edges.any? { |e| e.to == id && e.from == src && e.rule == rule }

        @edges << Edge.new(to: id, from: src, rule: rule, **span)
      end
      self
    end

    def node(id) = @nodes[id]

    # Drops a node and its edges (a derived statement the compiler made and then did not keep).
    def forget(id)
      @nodes.delete(id)
      @edges.reject! { |e| e.to == id || e.from == id }
      self
    end

    # The edges into `id`: what it takes its type from, directly.
    def sources(id) = @edges.select { |e| e.to == id }

    # The edges out of `id`: what takes its type from it, directly.
    def dependents(id) = @edges.select { |e| e.from == id }

    # Every node that depends on `id`, directly or not, sorted: what a change to `id` reaches.
    def impact(id)
      seen = {}
      queue = [id]
      until queue.empty?
        dependents(queue.shift).each do |e|
          next if seen[e.to]

          seen[e.to] = true
          queue << e.to
        end
      end
      seen.keys.sort
    end

    class UnknownNode < StandardError; end

    # Every edge on a path into `id`: the whole derivation of it, upstream.
    def upstream(id)
      seen = {}
      queue = [id]
      until queue.empty?
        sources(queue.shift).each do |e|
          next if seen[e]

          seen[e] = true
          queue << e.from
        end
      end
      seen.keys.sort_by { |e| [e.to, e.from, e.rule] }
    end

    # What `axum_dsl graph` prints: the whole graph, or with `why:` the derivation of one node, or with `impact:` what
    # one node reaches. The language server's virtual documents will call this too. Text or a JSON document.
    def report(why: nil, impact: nil, json: false)
      edge_line = ->(e) { "#{e.to} <- #{e.from} (#{e.rule})" }
      if why
        known!(why)
        return JSON.pretty_generate("node" => why, "edges" => upstream(why).map { |e| e.to_h.compact.transform_keys(&:to_s) }) if json

        self.why(why).join("\n")
      elsif impact
        known!(impact)
        reached = self.impact(impact)
        return JSON.pretty_generate("node" => impact, "impact" => reached) if json

        reached.empty? ? "nothing takes its type from #{impact}" : reached.join("\n")
      elsif json
        JSON.pretty_generate(to_h)
      else
        ["#{@nodes.size} nodes, #{@edges.size} edges", *@edges.sort_by { |e| [e.to, e.from, e.rule] }.map(&edge_line)].join("\n")
      end
    end

    def known!(id)
      raise UnknownNode, "no node `#{id}` (the graph has #{@nodes.size} nodes; `axum_dsl graph FILE` lists the edges)" unless @nodes.key?(id)
    end    # The derivation of `id` as lines: the node, then each node it takes its type from and, indented, theirs.
    def why(id, depth = 0, path = [])
      return ["no node `#{id}`"] unless @nodes[id]

      lines = depth.zero? ? [describe(@nodes[id])] : []
      return lines if path.include?(id)

      sources(id).each do |e|
        lines << "#{'  ' * (depth + 1)}<- #{describe(@nodes[e.from])} (#{e.rule})"
        lines.concat(why(e.from, depth + 1, path + [id]))
      end
      lines
    end

    # `field:RoomRow.id (i64, derived, file:line)`
    def describe(n)
      info = [n.type, n.origin.to_s, n.place].compact.join(", ")
      "#{n.id} (#{info})"
    end

    # Where `id` is, for a jump: { file:, line:, col:, end_line:, end_col: } or nil.
    def location_of(id)
      n = @nodes[id]
      n&.located? ? { file: n.file, line: n.line, col: n.col, end_line: n.end_line, end_col: n.end_col } : nil
    end

    # The smallest located nodes whose span covers (line, col) of `file`: what the cursor is on.
    def nodes_at(file, line, col)
      covering = @nodes.values.select do |n|
        n.located? && n.file == file && Lsp::Spans.covers?({ line: n.line, col: n.col, end_line: n.end_line, end_col: n.end_col }, line, col)
      end
      size = ->(n) { [n.end_line - n.line, n.end_line == n.line ? n.end_col - n.col : n.end_col] }
      best = covering.map(&size).min
      covering.select { |n| size.call(n) == best }.sort_by(&:id)
    end

    # The derivation for a hover: for each derived node at the position, what it takes its type from.
    def hover_markdown(file, line, col)
      # An instance variable (`ivar:` node) is a source, not a derivation: its hover lists the views that read it.
      derived = nodes_at(file, line, col).select { |n| sources(n.id).any? || (n.kind == "ivar" && dependents(n.id).any?) || n.kind == "expr" }.first(20)
      return nil if derived.empty?

      derived.map do |n|
        if n.kind == "ivar"
          next "**View input** `#{n.id}`#{n.type ? " : `#{n.type}`" : ''}\n\nread by:\n#{dependents(n.id).map { |e| "- `#{e.to}`" }.join("\n")}"
        end

        # An expr is named with its owner (`expr:User.title` is the model's, `expr:Timestamps.created_ms` a concern's) and says where it is written.
        next "**Expression** `#{n.id}`#{n.type ? " : `#{n.type}`" : ''}#{n.place ? " (#{n.place})" : ''}" if n.kind == "expr" && sources(n.id).empty?

        "**Type derivation** `#{n.id}`#{n.type ? " : `#{n.type}`" : ''}\n\n#{sources(n.id).map { |e| "- `#{e.from}` (#{e.rule})" }.join("\n")}"
      end.join("\n\n")
    end

    # { "nodes" => [...], "edges" => [...] }, sorted so the same compile prints the same document.
    def to_h
      { "nodes" => @nodes.values.sort_by(&:id).map { |n| n.to_h.compact.transform_keys(&:to_s).merge("origin" => n.origin.to_s) },
        "edges" => @edges.sort_by { |e| [e.to, e.from, e.rule] }.map { |e| e.to_h.compact.transform_keys(&:to_s) } }
    end

    # The graph is acyclic by construction (a type comes from things typed before it); this proves it.
    def acyclic?
      strongly_connected_components.all? { |c| c.size == 1 && sources(c.first).none? { |e| e.from == c.first } }
    end

    def tsort_each_node(&) = @nodes.each_key(&)
    def tsort_each_child(id, &) = sources(id).map(&:from).each(&)

    private

    def put(id, origin, at, type)
      span = span_of(at)
      n = (@nodes[id] ||= Node.new(id: id, kind: kind_of(id), origin: origin))
      n.origin = :derived if origin == :derived
      n.type ||= type
      unless n.located?
        n.file = span[:file]
        n.line = span[:line]
        n.col = span[:col]
        n.end_line = span[:end_line]
        n.end_col = span[:end_col]
      end
      n
    end

    def kind_of(id) = id[/\A[a-z_]+/].to_s

    # file/line/col/end_line/end_col of `at`, for the Node and Edge structs; empty when it has no place.
    def span_of(at)
      case at
      when nil then {}
      when String
        file, line = at.match(/\A(.+):(\d+)\z/)&.captures
        file ? { file: AxumDsl.canon(file), line: line.to_i, col: 1, end_line: line.to_i, end_col: 10_000 } : {} # the whole line
      when Prism::Location then location_span(at)
      else at.respond_to?(:location) ? location_span(at.location) : {}
      end
    end

    def location_span(loc)
      file = AxumDsl::SOURCE_FILES[loc.send(:source)]&.last or return {}
      { file: file, line: loc.start_line, col: loc.start_column + 1, end_line: loc.end_line, end_col: loc.end_column + 1 }
    end
  end
end
