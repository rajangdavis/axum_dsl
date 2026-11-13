# frozen_string_literal: true

module AxumDsl
  module Db
    # Reads the body of a `query` or `execute` written as a relation (docs/database.md, "Queries as relations") from
    # its Prism nodes into Db::Rel values, and renders ONE statement from them. A body is one method chain whose
    # implicit receiver is the model's own relation:
    #
    #   visible_to(arg(:user_id)).where(id: arg(:id)).select(:id, name: coalesce(:name, ""))
    #
    # Only the operations listed in STEPS, the model's scopes (inlined, their parameters bound to the values given)
    # and one closing terminal are read; anything else is refused with `bad(node, message, word:, from:)` (the
    # reader's diagnostics, so every message starts with FILE:LINE:COL:). Needs `axum_dsl` and `db/rel` loaded.
    #
    #   Chain.new(model: "Room", models: Db::Models, schema: Db::Schema, args: { "id" => "i64" },
    #             label: "query `room`", kind: "query", bad: method(:bad)).call(statements_node, returns)
    #     => { sql:, returns: } as Db::Rel's terminals answer; a `destroy` with dependents also answers
    #        sqls: every statement in the order it runs (sql: is the last, the root's)
    #
    # `returns` is the IR's `returns:` hash of a query ({ "shape" => "one" | "list", "record" => } or
    # { "shape" => "scalar", "type" =>, "nilable" => }), nil for an execute. `args` maps each declared argument to
    # its type name.
    class Chain
      STEPS = %w[where where_not where_exists where_not_exists or joins left_joins select order limit last offset distinct].freeze
      CONDITIONS = %w[where where_not where_exists where_not_exists].freeze
      READS = %w[count exists pick].freeze
      WRITES = %w[touch delete update update_all destroy].freeze
      TERMINALS = (READS + WRITES + %w[insert insert_from]).freeze
      COMPARISONS = { "gt" => ">", "gte" => ">=", "lt" => "<", "lte" => "<=", "like" => "LIKE" }.freeze

      def initialize(model:, models:, schema:, args:, label:, kind:, bad:, used: {})
        @model = model
        @models = models
        @schema = schema
        @args = args
        @label = label
        @kind = kind
        @bad = bad
        @used = used
      end

      def call(body, returns)
        @body = body
        @returns = returns
        @root = @models.table(@model)
        @rel = Rel.from(@root)
        @joined = {}
        @selected = false
        @env = {}
        @stack = []
        steps = chain(single(body))
        term = nil
        steps.each_with_index do |step, i|
          if TERMINALS.include?(step.name.to_s)
            bad(step, "`#{step.name}` ends the chain; nothing can follow it") unless i == steps.size - 1
            term = step
          else
            apply(step)
          end
        end
        out = finish(term, steps)
        unused = @args.keys - @used.keys
        bad(body, "#{@label}: `args:` declares `#{unused.first}` but the chain never uses `arg(:#{unused.first})`") unless unused.empty?
        out
      end

      # A subrelation (`Message.where(...).select(:room_id)`, where a value may stand): this chain's model's relation
      # read from `body`, whose root receiver is the model constant. It ends in a `select` of exactly one value and
      # answers the Db::Rel relation; the arguments it uses count as the enclosing statement's.
      # With `pairs` (the `[column, value node]` of `insert_from`) the chain has no `select`: it answers the relation and
      # the values, each read in this model's frame (a Symbol is one of its columns).
      def subrelation(body, pairs: nil)
        @body = body
        @root = @models.table(@model)
        @rel = Rel.from(@root)
        @joined = {}
        @selected = false
        @env = {}
        @stack = []
        steps = chain(body, const_root: true)
        steps.each do |step|
          if TERMINALS.include?(step.name.to_s)
            bad(step, pairs ? "the relation given to `insert_from` is rows, so `#{step.name}` can not be in it" : "a subrelation of model #{@model} ends in `select`, so `#{step.name}` can not be in it")
          end
          bad(step, "the relation given to `insert_from` takes no `select`: the values are its `column: value` pairs") if pairs && step.name.to_s == "select"
          apply(step)
        end
        return [@rel, pairs.to_h { |column, node| [column, source_value(node)] }] if pairs

        unless steps.last.name.to_s == "select"
          bad(steps.last, "a subrelation of model #{@model} ends in `select(:column)` or `select(alias: expression)` with one value, not `#{steps.last.name}`")
        end
        size = @rel.selection.size
        bad(steps.last, "a subrelation of model #{@model} selects exactly one value (`select(:column)` or `select(alias: expression)`), not #{size}") unless size == 1
        @rel
      end

      private

      def bad(node, message, word: nil, from: nil) = @bad.call(node, message, word: word, from: from)

      def nodename(node) = node.class.name.split("::").last

      def tables = @schema.tables

      # Only a call into Db::Rel goes through here: its errors have no position, so they land on the whole body.
      def render
        yield
      rescue AxumDsl::CompileError => e
        bad(@body, "#{@label}: #{e.message}")
      end

      # A block or lambda body is one statement.
      def single(node)
        return node unless node.is_a?(Prism::StatementsNode)

        bad(node, "a relation is one expression, a method chain; this has #{node.body.size} statements") unless node.body.size == 1
        node.body.first
      end

      # The calls of a chain, innermost first. The first has no receiver: it is called on the model's own relation.
      def chain(node, const_root: false)
        list = []
        cur = node
        while cur
          break if const_root && (cur.is_a?(Prism::ConstantReadNode) || cur.is_a?(Prism::ConstantPathNode))

          unless cur.is_a?(Prism::CallNode)
            bad(cur, "a relation is a method chain on the model's own relation, such as `where(id: arg(:id))` with no receiver before it; got #{nodename(cur)}")
          end
          bad(cur.block, "`#{cur.name}` takes no block in a relation chain") if cur.block
          list.unshift(cur)
          cur = cur.receiver
        end
        list
      end

      # [positional argument nodes, keyword AssocNodes].
      def call_args(node)
        list = (node.arguments&.arguments || []).dup
        kw = list.last.is_a?(Prism::KeywordHashNode) ? list.pop : nil
        [list, kw ? kw.elements : []]
      end

      def pair_key(el)
        ok = el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode)
        bad(el, "write `column: value` pairs (no splat, no string keys); got #{nodename(el)}") unless ok
        bad(el, "write `column: value`, not the shorthand `#{el.key.unescaped}:`") if el.value.is_a?(Prism::ImplicitNode)
        el.key.unescaped
      end

      def symbol(node, what)
        bad(node, "#{what} is a symbol such as `:name`; got #{nodename(node)}") unless node.is_a?(Prism::SymbolNode)
        node.unescaped
      end

      def no_args(node)
        list, kw = call_args(node)
        bad(node, "`#{node.name}` takes no arguments") unless list.empty? && kw.empty?
      end

      # --- steps ------------------------------------------------------------------------------------------------

      def apply(step)
        name = step.name.to_s
        case name
        when "where" then add_where(step, false)
        when "where_not" then add_where(step, true)
        when "where_exists" then add_exists(step, false)
        when "where_not_exists" then add_exists(step, true)
        when "or" then add_or(step)
        when "joins" then add_joins(step)
        when "left_joins" then add_joins(step, left: true)
        when "select" then add_select(step)
        when "order" then add_order(step)
        when "limit" then add_limit(step)
        when "last" then add_last(step)
        when "offset" then add_offset(step)
        when "distinct"
          no_args(step)
          @rel = @rel.distinctly
        else
          scope = @models.scope(@model, name)
          scope ? apply_scope(step, scope) : unknown_step(step)
        end
      end

      def unknown_step(step)
        name = step.name.to_s
        scopes = @models.scope_names(@model)
        if name == "first" || name == "all"
          bad(step, "`#{name}` is implied by `returns:` (`:Record?` is the first row, `list(:Record)` every row); leave it out")
        end
        ends = (@kind == "query" ? READS : WRITES) + %w[insert insert_from]
        allowed = STEPS + scopes
        bad(step, "`#{name}` is not a relation operation here (operations: #{allowed.join(', ')}; ends the chain: #{ends.join(', ')})",
            word: name, from: allowed + ends)
      end

      def apply_scope(step, scope)
        name = scope[:name]
        bad(step, "scope `#{name}` calls itself (#{(@stack + [name]).join(' -> ')}); a scope can not recurse") if @stack.include?(name)
        list, kw = call_args(step)
        unless kw.empty? && list.size == scope[:params].size
          bad(step, "scope `#{name}` takes #{scope[:params].size} value(s)#{scope[:params].empty? ? '' : " (#{scope[:params].join(', ')})"}, got #{list.size + kw.size}")
        end
        values = list.map { |n| eq_value(n) } # read in the caller's frame, before the scope's own
        saved = @env
        @env = scope[:params].zip(values).to_h
        @stack.push(name)
        begin
          chain(single(scope[:body])).each do |s|
            bad(s, "scope `#{name}` is a relation, so it can not end in `#{s.name}`; put that on the query") if TERMINALS.include?(s.name.to_s)
            apply(s)
          end
        ensure
          @stack.pop
          @env = saved
        end
      end

      # --- where, joins ------------------------------------------------------------------------------------------

      def add_where(step, negate)
        list, kw = call_args(step)
        bad(step, "`#{step.name}` needs conditions: `#{step.name}(column: value)` or a comparison such as `gt(:column, value)`") if list.empty? && kw.empty?
        list.each do |n|
          if n.is_a?(Prism::CallNode) && n.receiver.nil? && n.name == :expr
            @rel = @rel.where(condition(n, negate))
            next
          end
          if n.is_a?(Prism::CallNode) && n.receiver.nil? && n.name == :attached
            @rel = @rel.where(Rel::Cond.new(attached_value(n), negate))
            next
          end
          cmp = comparison(n) or
            bad(n, "`#{step.name}` takes `column: value` pairs or a comparison (#{COMPARISONS.keys.join(', ')}), got #{nodename(n)}")
          bad(n, "`where_not` takes `column: value` pairs; negate a comparison with the opposite one") if negate
          @rel = @rel.where(cmp)
        end
        kw.each { |el| add_pair(el, negate) }
      end

      # `where(expr(:visible, include_banned: arg(:b)))`: a declared :bool expression as the condition, parenthesised;
      # `where_not` negates it.
      def condition(node, negate)
        found = expr_value(node)
        unless found.type == :bool
          bad(node, "expr `#{call_args(node)[0][0].unescaped}` is :#{found.type}, and a condition needs a :bool expr (declare it with `type: :bool`)")
        end
        Rel::Cond.new(found, negate)
      end

      def add_pair(el, negate)
        key = pair_key(el)
        if el.value.is_a?(Prism::HashNode)
          table = joined_table(el.key, key)
          el.value.elements.each do |inner|
            column = pair_key(inner)
            bad(inner.value, "a joined table's condition is `column: value`, not another hash") if inner.value.is_a?(Prism::HashNode)
            add_equality(Rel::Col.new(table, check_column(inner.key, table, column)), inner.value, negate)
          end
        else
          add_equality(Rel::Col.new(nil, check_column(el.key, @root, key)), el.value, negate)
        end
      end

      def add_equality(col, node, negate)
        eq = Rel::Eq.new(col, eq_value(node))
        @rel = @rel.where(negate ? Rel::Not.new(eq) : eq)
      end

      def comparison(node)
        return nil unless node.is_a?(Prism::CallNode) && node.receiver.nil? && COMPARISONS.key?(node.name.to_s)

        list, kw = call_args(node)
        bad(node, "`#{node.name}` takes a column (or `expr(:name)`) and a value: `#{node.name}(:column, value)`") unless list.size == 2 && kw.empty?
        right = node.name != :like && model_chain?(list[1]) ? read_subrelation(list[1]) : value(list[1])
        Rel::Cmp.new(order_value(list[0]), COMPARISONS.fetch(node.name.to_s), right)
      end

      # `where_exists(:assoc, column: value, ...)`: EXISTS over the association's table, correlated by the keys `joins`
      # would join on, with the conditions on that table. A through association is refused.
      def add_exists(step, negate)
        list, kw = call_args(step)
        bad(step, "`#{step.name}` takes an association and optional conditions: `#{step.name}(:memberships, user_id: arg(:user_id))`") unless list.size == 1
        name = symbol(list[0], "an association name")
        assoc = association(list[0], @model, name)
        bad(list[0], "`#{step.name}` does not support the `through:` association `:#{name}`; name an association with its own keys, or use `joins(:#{name})`") if assoc[:through]
        target = assoc[:target_table]
        inner = Rel.from(target)
        kw.each do |el|
          key = pair_key(el)
          bad(el.value, "a condition of `#{step.name}` is `column: value`, not a hash") if el.value.is_a?(Prism::HashNode)
          inner = inner.where(Rel::Eq.new(Rel::Col.new(nil, check_column(el.key, target, key)), eq_value(el.value)))
        end
        @rel = @rel.where(Rel::Exists.new(inner, join_of(assoc, @root), negate))
      end

      # `where(a).or(where(b))`, as Rails: every condition so far is the left side, the conditions of the argument (a
      # chain of conditions and scopes that only add conditions) the right side, joined with OR. What follows is ANDed.
      def add_or(step)
        list, kw = call_args(step)
        bad(step, "`or` takes one chain of conditions: `where(status: 0).or(where(status: 2))`") unless list.size == 1 && kw.empty?
        bad(step, "`or` needs a condition before it: `where(status: 0).or(where(status: 2))`") if @rel.predicates.empty?
        left = @rel
        @rel = Rel.from(@root)
        chain(list[0]).each do |s|
          name = s.name.to_s
          if (STEPS + TERMINALS).include?(name) && !CONDITIONS.include?(name)
            bad(s, "`or` takes a chain of `where`, `where_not`, `where_exists`, `where_not_exists` and scopes that only add conditions; `#{name}` can not be in it")
          end
          apply(s)
          unless @rel.joins.empty? && @rel.selection.nil? && @rel.orders.empty? && @rel.limit.nil?
            bad(s, "scope `#{name}` does more than add conditions (joins, select, order or limit), so `or` can not take it")
          end
          bad(s, "scope `#{name}` sets distinct, so `or` can not take it") if @rel.distinct
        end
        bad(list[0], "the chain given to `or` adds no condition") if @rel.predicates.empty?
        @rel = left.with(predicates: [Rel::OrWhere.new(left.predicates, @rel.predicates)].freeze)
      end

      # The table behind a joined association (or a joined table) named in a condition.
      def joined_table(node, key)
        table = @joined[key] || (@joined.value?(key) ? key : nil)
        return table if table

        have = @joined.keys
        bad(node, "`#{key}` is not joined#{have.empty? ? '' : " (joined: #{have.join(', ')})"}; join the association first with `joins(:#{key})`",
            word: key, from: have)
      end

      # `joins` and `left_joins` (LEFT OUTER JOIN: the columns of what it joins may be NULL).
      def add_joins(step, left: false)
        list, kw = call_args(step)
        bad(step, "`#{step.name}` takes association names: `#{step.name}(:memberships)`") if list.empty? || !kw.empty?
        list.each do |n|
          name = symbol(n, "an association name")
          bad(n, "`:#{name}` is already joined") if @joined.key?(name)
          assoc = association(n, @model, name)
          hops(n, assoc).each do |hop, owner|
            @rel = @rel.join(join_of(hop, owner, left))
            @joined[hop[:name]] ||= hop[:target_table]
          end
          @joined[name] = assoc[:target_table]
        end
      end

      def association(node, model, name)
        found = @models.association(model, name)
        return found if found

        names = @models.associations(model).map { |a| a[:name] }
        bad(node, "model \"#{model}\" has no association `:#{name}`#{names.empty? ? ' (it declares none)' : " (associations: #{names.join(', ')})"}",
            word: name, from: names)
      rescue Db::Models::Unresolved => e
        bad(node, e.message, word: e.word, from: e.from)
      end

      # [association, the table that owns its keys] for each join a (possibly through) association needs.
      def hops(node, assoc)
        return [[assoc, @root]] unless assoc[:through]

        via = association(node, @model, assoc[:through])
        far = association(node, via[:target_model], assoc[:source])
        [[via, @root], [far, via[:target_table]]]
      end

      def join_of(assoc, owner, left = false)
        target = assoc[:target_table]
        if assoc[:kind] == :belongs_to
          Rel::Join.new(target, nil, Rel::Col.new(target, "id"), Rel::Col.new(owner, assoc[:foreign_key]), nil, left)
        else
          Rel::Join.new(target, nil, Rel::Col.new(target, assoc[:foreign_key]), Rel::Col.new(owner, assoc[:owner_key]), on_conditions(assoc), left)
        end
      end

      # What a has_many or has_one adds to its ON clause besides the keys: the polymorphic type and the fixed conditions
      # of its `-> { where(...) }`, each `column = literal`.
      def on_conditions(assoc)
        assoc[:conditions] ? (assoc[:discriminator] || {}).merge(assoc[:conditions]) : assoc[:discriminator]
      end

      # --- select, order, limit ----------------------------------------------------------------------------------

      def add_select(step)
        bad(step, "`select` is given twice") if @selected
        list, kw = call_args(step)
        bad(step, "`select` needs columns: `select(:id, name: coalesce(:name, \"\"))`") if list.empty? && kw.empty?
        items = list.map do |n|
          unless n.is_a?(Prism::SymbolNode) || (n.is_a?(Prism::CallNode) && n.name == :col)
            bad(n, "a selected item without a name is a column, `:name` or `col(:assoc, :column)`; give anything else a name: `name: #{n.respond_to?(:name) ? n.name : 'expression'}(...)`")
          end
          select_value(n)
        end
        kw.each { |el| items << Rel::Sel.new(select_value(el.value), pair_key(el)) }
        names = items.map { |i| i.is_a?(Rel::Sel) ? i.name : i.column }
        dup = names.find { |nm| names.count(nm) > 1 }
        bad(step, "`select` names `#{dup}` twice") if dup
        @selected = true
        @rel = @rel.selecting(*items)
      end

      # `aggregate: true` only for the value of a `pick`, where `group_concat` may stand (it reads the whole relation).
      def select_value(node, aggregate: false)
        case node
        when Prism::SymbolNode then Rel::Col.new(nil, check_column(node, @root, node.unescaped))
        when Prism::StringNode, Prism::IntegerNode, Prism::TrueNode, Prism::FalseNode then literal(node)
        when Prism::NilNode then bad(node, "a selected `nil` has no type, so it can not be a value; select a string, integer, true or false literal, or a column")
        when Prism::CallNode
          bad(node, "`#{node.name}` is not a selectable value") unless node.receiver.nil?
          case node.name
          when :col then column_value(node)
          when :expr then expr_value(node)
          when :attached then attached_value(node)
          when :coalesce
            list, kw = call_args(node)
            bad(node, "`coalesce` takes a column or `expr(:name)` and at least one more value: `coalesce(:name, \"\")`") if list.size < 2 || !kw.empty?
            first = group_concat?(list[0]) ? select_value(list[0], aggregate: aggregate) : order_value(list[0])
            Rel::Fn.new("coalesce", [first, *list[1..].map { |n| value(n) }], nil)
          when :group_concat
            bad(node, "`group_concat` is an aggregate over the whole relation, so it is only the value of a `pick`: `pick(coalesce(group_concat(:column), \"\"))`") unless aggregate
            list, kw = call_args(node)
            bad(node, "`group_concat` takes one column: `group_concat(:blob_id)`") unless list.size == 1 && kw.empty?
            Rel::Fn.new("group_concat", [column_value(list[0])], nil)
          else bad(node, "`#{node.name}` is not selectable; use `:column`, `coalesce(:column, literal)`, `col(:assoc, :column)` or `expr(:name)`")
          end
        else bad(node, "a selected value is `:column`, `coalesce(:column, literal)`, `col(:assoc, :column)`, `expr(:name)` or a string, integer, true or false literal, got #{nodename(node)}")
        end
      end

      def group_concat?(node) = node.is_a?(Prism::CallNode) && node.receiver.nil? && node.name == :group_concat

      # What `pick` takes: a column, an `expr`, or an aggregate (`group_concat(:col)`, alone or as the first value of `coalesce`).
      def pick_value(node)
        wraps = node.is_a?(Prism::CallNode) && node.receiver.nil? && node.name == :coalesce && group_concat?(call_args(node)[0].first)
        group_concat?(node) || wraps ? select_value(node, aggregate: true) : order_value(node)
      end

      # `:column` of the model's table, or `col(:assoc, :column)` of a joined one.
      def column_value(node)
        return Rel::Col.new(nil, check_column(node, @root, node.unescaped)) if node.is_a?(Prism::SymbolNode)

        unless node.is_a?(Prism::CallNode) && node.receiver.nil? && node.name == :col
          bad(node, "a column is `:name`, or `col(:assoc, :column)` for a joined table's; got #{nodename(node)}")
        end
        list, kw = call_args(node)
        bad(node, "`col` takes a joined association and a column: `col(:memberships, :user_id)`") unless list.size == 2 && kw.empty?
        table = joined_table(list[0], symbol(list[0], "a joined association"))
        Rel::Col.new(table, check_column(list[1], table, symbol(list[1], "a column")))
      end

      def check_column(node, table, name)
        names = @schema.columns(table).map { |c| c[:name] }
        return name if names.include?(name)

        bad(node, "table `#{table}` has no column `#{name}` (columns: #{names.join(', ')})", word: name, from: names)
      end

      def add_order(step)
        list, kw = call_args(step)
        bad(step, "`order` needs a column: `order(:name)`, `order(created_at: :desc)`, `order(name: :nocase)`, `order(col(:users, :name) => :desc)` or `order(expr(:lower_name))`") if list.empty? && kw.empty?
        terms = list.map { |n| Rel::Order.new(order_value(n), false, false) }
        kw.each do |el|
          call_key = el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::CallNode)
          key = pair_key(el) unless call_key
          dir = el.value
          bad(dir, "an order direction is `:asc`, `:desc` or `:nocase` (ascending, ignoring case)") unless dir.is_a?(Prism::SymbolNode) && %w[asc desc nocase].include?(dir.unescaped)
          value = call_key ? order_value(el.key) : Rel::Col.new(nil, check_column(el.key, @root, key))
          terms << Rel::Order.new(value, dir.unescaped == "desc", dir.unescaped == "nocase")
        end
        @rel = @rel.order_by(*terms)
      end

      # What an order sorts by: a column (`:name`, `col(:assoc, :column)`) or a declared `expr(:name)`.
      def order_value(node)
        node.is_a?(Prism::CallNode) && node.receiver.nil? && node.name == :expr ? expr_value(node) : column_value(node)
      end

      def add_limit(step)
        bad(step, "`limit` can not follow `last`; `last(n)` is the limit") if @rel.tail
        @rel = @rel.limited(bound_value(step, true))
      end

      # `order(...).last(n)`: the last n rows of the order, handed back in that order.
      def add_last(step)
        bad(step, "`last` is given twice") if @rel.tail
        bad(step, "`last(n)` is the limit, so it can not be combined with `limit`") if @rel.limit
        @rel = @rel.last_of(bound_value(step, true))
      end

      def add_offset(step)
        bad(step, "`offset` follows `limit`: `limit(10).offset(20)`") if @rel.limit.nil?
        bad(step, "`offset` can not be combined with `last`") if @rel.tail
        bad(step, "`offset` is given twice") if @rel.offset
        @rel = @rel.offset_by(bound_value(step, false))
      end

      # The one argument of `limit`, `last` and `offset`: an integer, or `arg(:name)` of an :i64.
      def bound_value(step, positive)
        list, kw = call_args(step)
        bad(step, "`#{step.name}` takes one integer or `arg(:name)`") unless list.size == 1 && kw.empty?
        v = value(list[0])
        if v.is_a?(Rel::Arg)
          bad(list[0], "`#{step.name}` takes an :i64 argument, `#{v.name}` is :#{@args[v.name]}") unless @args[v.name] == "i64"
          v
        elsif v.is_a?(Rel::Lit) && v.value.is_a?(Integer) && (positive ? v.value.positive? : !v.value.negative?)
          v.value
        else
          bad(list[0], "`#{step.name}` takes #{positive ? 'a positive' : 'a non-negative'} integer or `arg(:name)`")
        end
      end

      # --- values ------------------------------------------------------------------------------------------------

      # What a column is compared with: a value, a list of literals (IN), or `in_ids(arg(:ids))`.
      def eq_value(node)
        case node
        when Prism::ArrayNode then list_of_literals(node)
        when Prism::LocalVariableReadNode then local(node)
        when Prism::CallNode
          if model_chain?(node) then read_subrelation(node)
          else node.receiver.nil? && node.name == :in_ids ? in_ids(node) : value(node)
          end
        when Prism::ConstantReadNode, Prism::ConstantPathNode
          bad(node, "a model is followed by a relation ending in `select`: `Message.where(...).select(:room_id)`")
        else value(node)
        end
      end

      # A call chain whose root receiver is a constant: another model's relation.
      def model_chain?(node)
        return false unless node.is_a?(Prism::CallNode) && node.receiver

        cur = node
        cur = cur.receiver while cur.is_a?(Prism::CallNode) && cur.receiver
        cur.is_a?(Prism::ConstantReadNode) || cur.is_a?(Prism::ConstantPathNode)
      end

      # `Message.where(creator_id: arg(:user_id)).select(:room_id)` where a value may stand: read by a Chain of that model.
      def read_subrelation(node, pairs: nil)
        cur = node
        cur = cur.receiver while cur.is_a?(Prism::CallNode)
        name = cur.is_a?(Prism::ConstantReadNode) ? cur.name.to_s : cur.full_name
        bad(node, "a subrelation is written in the statement, not in a scope") unless @stack.empty?
        unless @models.model?(name)
          bad(cur, "no model `#{name}` is declared (declared: #{@models.model_names.join(', ')})", word: name, from: @models.model_names)
        end
        bad(cur, "model `#{name}` names no `table:`, so it has no relation to read") unless @models.table(name)
        Chain.new(model: name, models: @models, schema: @schema, args: @args, label: @label, kind: @kind, bad: @bad, used: @used).subrelation(node, pairs: pairs)
      end

      def list_of_literals(node)
        bad(node, "an empty list can not be compared with IN") if node.elements.empty?
        node.elements.map do |el|
          lit = literal(el)
          bad(el, "a list holds string, integer, true or false literals, got #{nodename(el)}") if lit.nil? || lit.value.nil?
          lit
        end
      end

      def literal(node)
        case node
        when Prism::StringNode then Rel::Lit.new(node.unescaped)
        when Prism::IntegerNode then Rel::Lit.new(node.value)
        when Prism::TrueNode then Rel::Lit.new(true)
        when Prism::FalseNode then Rel::Lit.new(false)
        when Prism::NilNode then Rel::Lit.new(nil)
        end
      end

      def local(node)
        name = node.name.to_s
        return @env[name] if @env.key?(name)

        bad(node, "`#{name}` is a local variable; a relation has none#{@env.empty? ? '' : " (this scope's parameters: #{@env.keys.join(', ')})"}")
      end

      def value(node)
        lit = literal(node)
        return lit if lit

        case node
        when Prism::LocalVariableReadNode
          got = local(node)
          bad(node, "`#{node.name}` stands for a list here; only `where(column: #{node.name})` takes one") if got.is_a?(Array) || got.is_a?(Rel::InIds)
          got
        when Prism::CallNode then call_value(node)
        else bad(node, "not a value here: #{nodename(node)}; a value is arg(:name), a string, integer, true, false or nil literal, or expr(:name)")
        end
      end

      def call_value(node)
        bad(node, "not a value here: `.#{node.name}` on something; a value is arg(:name), a literal or expr(:name)") unless node.receiver.nil?
        case node.name
        when :arg then arg_value(node)
        when :expr then expr_value(node)
        when :in_ids then bad(node, "`in_ids` goes where a column is compared: `where(id: in_ids(arg(:ids)))`")
        else bad(node, "`#{node.name}` is not a value here; a value is arg(:name), a string, integer, true, false or nil literal, or expr(:name)")
        end
      end

      def arg_value(node)
        bad(node, "a scope takes its values as parameters; pass `arg(:name)` where the scope is called") unless @stack.empty?
        list, kw = call_args(node)
        bad(node, "`arg` takes one declared name: `arg(:name)`") unless list.size == 1 && kw.empty? && list[0].is_a?(Prism::SymbolNode)
        name = list[0].unescaped
        unless @args.key?(name)
          declared = @args.empty? ? "none is declared" : "declared: #{@args.keys.join(', ')}"
          bad(list[0], "#{@label}: `arg(:#{name})` is not in `args:` (#{declared})", word: name, from: @args.keys)
        end
        @used[name] = true
        Rel::Arg.new(name)
      end

      def in_ids(node)
        list, kw = call_args(node)
        bad(node, "`in_ids` takes the argument that holds the ids: `in_ids(arg(:ids))`") unless list.size == 1 && kw.empty?
        v = value(list[0])
        bad(list[0], "`in_ids` takes `arg(:name)`") unless v.is_a?(Rel::Arg)
        unless @args[v.name] == "string"
          bad(list[0], "`in_ids` reads a comma-separated string of ids (json_each('[' || :#{v.name} || ']')), so `#{v.name}` is declared :string, not :#{@args[v.name]}")
        end
        Rel::InIds.new(v.name)
      end

      def expr_value(node)
        list, kw = call_args(node)
        bad(node, "`expr` takes a declared expression and, for one written with `of:`, a joined table: `expr(:user_title)` or `expr(:user_title, :users)`; one declared with `args:` also takes its binds: `expr(:is_current, user_id: arg(:user_id))`") unless (1..2).cover?(list.size)
        name = symbol(list[0], "an expr name")
        # Whose expr: the relation's model, or for `expr(:name, :assoc)` the model that owns the joined association's table (if one does).
        # An expr of an included concern is named for the model that includes it (`expr:User.updated_ms`).
        key = list[1] && symbol(list[1], "a joined association")
        joined = key && (@joined[key] || (@joined.value?(key) ? key : nil))
        model = key ? (joined && @models.model_for_table(joined)) : @model
        found = @models.expr(name, model: model)
        unless found
          names = @models.expr_names(model: model)
          hint = @models.expr_not_found_hint(name, model)
          bad(list[0], "no `expr :#{name}` is declared (declared#{model ? " for #{model}" : ""}: #{names.join(", ")})#{hint}", word: name, from: names)
        end
        table = nil
        if list[1]
          bad(list[1], "expr `#{name}` has no `of:`, so it applies to no table") unless found[:of]
          table = joined_table(list[1], key)
        end
        sql = found[:of] ? found[:sql].gsub("{#{found[:of]}}", "{t}") : found[:sql]
        Rel::Expr.new(sql, found[:type].to_sym, table, expr_binds(name, found, kw), [found[:concern] ? model : found[:model], name].compact.join("."))
      end

      # `attached(:avatar)`: whether the row has the file a `has_one_attached :avatar` of its model names, as an EXISTS over the
      # attachment row the derived `:avatar_attachment` association reads (the polymorphic type, the owner key, the name).
      def attached_value(node)
        list, kw = call_args(node)
        bad(node, "`attached` takes the name of a `has_one_attached` of the model: `attached(:avatar)`") unless list.size == 1 && kw.empty?
        name = symbol(list[0], "an attachment name")
        unless @models.attached(@model, name)
          names = @models.attached_names(@model)
          bad(list[0], "model \"#{@model}\" declares no `has_one_attached :#{name}`#{names.empty? ? " (it declares none)" : " (it declares: #{names.join(", ")})"}", word: name, from: names)
        end
        assoc = association(list[0], @model, "#{name}_attachment")
        conds = (assoc[:discriminator] || {}).map { |c, v| "#{c} = #{Rel.lit_sql(v)}" }
        conds << "#{assoc[:foreign_key]} = {t}.#{assoc[:owner_key]}"
        conds.concat((assoc[:conditions] || {}).map { |c, v| "#{c} = #{Rel.lit_sql(v)}" })
        Rel::Expr.new("EXISTS (SELECT 1 FROM #{assoc[:target_table]} WHERE #{conds.join(" AND ")})", :bool, nil, nil)
      end

      # The `name: value` binds of an `expr` call, for the `args:` its declaration lists: every one given once, none
      # unknown, none missing, each of the declared type (an `arg(:x)` of the statement, a literal or another expr).
      def expr_binds(name, found, kw)
        declared = found[:args] || {}
        given = {}
        kw.each do |el|
          key = pair_key(el)
          bad(el.key, "expr `#{name}` takes no binds (its declaration has no `args:`), so `#{key}:` can not be given") if declared.empty?
          type = declared[key] or
            bad(el.key, "expr `#{name}` has no bind `#{key}` (binds: #{declared.keys.join(', ')})", word: key, from: declared.keys)
          bad(el.key, "bind `#{key}` of expr `#{name}` is given twice") if given.key?(key)
          given[key] = bind_value(el.value, name, key, type)
        end
        missing = declared.keys - given.keys
        unless missing.empty?
          bad(kw.first || @body, "expr `#{name}` needs #{missing.map { |m| "`#{m}:`" }.join(', ')}: `expr(:#{name}, #{missing.first}: arg(:#{missing.first}))`")
        end
        given.empty? ? nil : given
      end

      def bind_value(node, name, key, type)
        v = value(node)
        got = case v
              when Rel::Arg then @args[v.name]
              when Rel::Expr then v.type.to_s
              when Rel::Lit
                bad(node, "bind `#{key}` of expr `#{name}` can not be nil") if v.value.nil?
                { String => "string", Integer => "i64" }.fetch(v.value.class, "bool")
              else bad(node, "bind `#{key}` of expr `#{name}` is `arg(:name)`, a literal or `expr(:name)`")
              end
        bad(node, "expr `#{name}` takes `#{key}` as :#{type}, but this value is :#{got}") unless got == type
        v
      end

      # --- the end of the chain ------------------------------------------------------------------------------------

      def finish(term, steps)
        name = term&.name&.to_s
        if name == "insert"
          bad(term, "`insert` is the whole chain: `insert(column: value, ...)`, with nothing before it") unless steps.size == 1
          return insert(term)
        end
        if name == "insert_from"
          bad(term, "`insert_from` is the whole chain: `insert_from(Model.where(...), column: value, ...)`, with nothing before it") unless steps.size == 1
          return insert_from(term)
        end
        return finish_execute(term, name) if @kind == "execute"

        bad(term, "`#{name}` changes data, so it belongs in an `execute`") if WRITES.include?(name)
        shape = @returns["shape"]
        if @rel.tail && (term || shape != "list")
          bad(term || @body, "`last` gives the last rows as a list: `order(...).last(n)` with `returns: list(:Record)` and no end of the chain")
        end
        if term.nil?
          if shape == "scalar"
            bad(@body, "#{@label} returns one value, so the chain ends in `count`, `exists` or `pick(:column)`")
          end
          return render { shape == "list" ? Rel.all(@rel, tables) : Rel.first(@rel, tables) }
        end
        bad(term, "`#{name}` gives one value, but `returns:` is a record; the chain with no terminal gives the rows") unless shape == "scalar"
        res = case name
              when "count"
                no_args(term)
                render { Rel.count(@rel, tables) }
              when "exists"
                no_args(term)
                render { Rel.exists(@rel, tables) }
              else
                list, kw = call_args(term)
                bad(term, "`pick` takes one column, expr or aggregate: `pick(:name)`") unless list.size == 1 && kw.empty?
                col = pick_value(list[0])
                render { Rel.pick(@rel, col, tables) }
              end
        check_scalar(term, res[:returns])
        res
      end

      def finish_execute(term, name)
        bad(@body, "#{@label} ends in a write: `touch`, `delete`, `destroy`, `update(...)`, `update_all(...)` or `insert(...)`") unless term
        bad(term, "`#{name}` reads, so it belongs in a `query`") if READS.include?(name)
        bad(term, "`last`, `offset` and `distinct` read rows, so they belong in a `query`, not before `#{name}`") if @rel.tail || @rel.offset || @rel.distinct
        case name
        when "touch"
          no_args(term)
          render { Rel.touch(@rel, tables) }
        when "delete"
          no_args(term)
          render { Rel.delete(@rel, tables) }
        when "destroy"
          no_args(term)
          finish_destroy(term)
        else
          values, = values_of(term, false)
          render { Rel.update(@rel, values, tables, stamp: name == "update") }
        end
      end

      # `destroy` deletes the row and what its model's `dependent:` associations say goes with it: Db::Rel.destroy with the
      # plan of Db::Models#destroy_plan, an ordered list of DELETEs ending in the root's. A model with no dependent is
      # the one DELETE `delete` is, so that is an ordinary statement; with dependents the statements run as one unit
      # (the call site is a `transaction`), `sqls` carries them all and `sql` is the root's, whose row count the
      # caller gets.
      def finish_destroy(term)
        plan = begin
          @models.destroy_plan(@model)
        rescue Db::Models::Unresolved => e
          bad(term, e.message, word: e.word, from: e.from)
        end
        sqls = render { Rel.destroy(@rel, plan, tables) }.map { |s| s[:sql] }
        { sql: sqls.last, sqls: (sqls if sqls.size > 1), returns: { shape: :execute } }
      end

      def insert(term)
        values, returning, on_duplicate = values_of(term, true)
        if @kind == "execute"
          bad(term, "`returning:` belongs to a `query` that returns a scalar, not an `execute`") if returning
        else
          bad(term, "an insert in a query needs `returning: :column` and a scalar `returns:`; to insert alone write an `execute`") unless returning && @returns["shape"] == "scalar"
        end
        res = render { Rel.insert(@root, values, tables, returning: returning, on_duplicate: on_duplicate) }
        check_scalar(term, res[:returns]) if @kind == "query"
        res
      end

      # `insert_from(User.where(status: 0), room_id: arg(:room_id), user_id: :id, on_duplicate: :skip)`: INSERT ... SELECT
      # into this model's table from another model's relation, whose columns the Symbol values name.
      def insert_from(term)
        bad(term, "`insert_from` changes data, so it belongs in an `execute`") unless @kind == "execute"
        list, kw = call_args(term)
        unless list.size == 1 && model_root?(list[0]) && !kw.empty?
          bad(term, "`insert_from` takes another model's relation and `column: value` pairs: `insert_from(User.where(status: 0), room_id: arg(:room_id), user_id: :id)`")
        end
        on_duplicate = nil
        pairs = []
        kw.each do |el|
          key = pair_key(el)
          bad(el.key, "`returning:` is not supported by `insert_from`") if key == "returning"
          if key == "on_duplicate"
            on_duplicate = on_duplicate_value(el.value)
            next
          end
          column = check_column(el.key, @root, key)
          bad(el.key, "`#{column}` is given twice") if pairs.any? { |c, _| c == column }
          pairs << [column, el.value]
        end
        bad(term, "`insert_from` needs at least one column: value") if pairs.empty?
        source, values = read_subrelation(list[0], pairs: pairs)
        render { Rel.insert_from(@root, source, values, tables, on_duplicate: on_duplicate) }
      end

      def model_root?(node) = model_chain?(node) || node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)

      # A value of `insert_from`, read in the source model's frame: `:column`, `col(:assoc, :column)`, `expr(:name)`, or
      # what `insert` takes.
      def source_value(node)
        return Rel::Col.new(nil, check_column(node, @root, node.unescaped)) if node.is_a?(Prism::SymbolNode)
        return column_value(node) if node.is_a?(Prism::CallNode) && node.receiver.nil? && node.name == :col

        v = value(node)
        bad(node, "setting a column to nil is not supported by relations yet") if v.is_a?(Rel::Lit) && v.value.nil?
        v
      end

      def on_duplicate_value(node)
        return :skip if node.is_a?(Prism::SymbolNode) && node.unescaped == "skip"

        bad(node, "`on_duplicate:` takes `:skip` (INSERT OR IGNORE), the only choice; got `#{node.slice}`")
      end

      # [{ column => value }, the returning: column or nil, the on_duplicate: value or nil] of `update(...)` or `insert(...)`.
      def values_of(term, allow_returning)
        list, kw = call_args(term)
        bad(term, "`#{term.name}` takes `column: value` pairs") unless list.empty? && !kw.empty?
        values = {}
        returning = nil
        on_duplicate = nil
        kw.each do |el|
          key = pair_key(el)
          if allow_returning && key == "returning"
            returning = check_column(el.value, @root, symbol(el.value, "the returning: column"))
            next
          end
          if allow_returning && key == "on_duplicate"
            on_duplicate = on_duplicate_value(el.value)
            next
          end
          column = check_column(el.key, @root, key)
          bad(el.key, "`#{column}` is given twice") if values.key?(column)
          v = value(el.value)
          bad(el.value, "setting a column to nil is not supported by relations yet") if v.is_a?(Rel::Lit) && v.value.nil? && allow_returning
          values[column] = v
        end
        bad(term, "`#{term.name}` needs at least one column: value") if values.empty?
        [values, returning, on_duplicate]
      end

      def check_scalar(term, got)
        want = [@returns["type"], @returns["nilable"] ? true : false]
        return if [got[:type].to_s, got[:optional]] == want

        hint = term.name == :pick && got[:optional] && !want[1] ? "; a pick may find no row or a NULL, so it is optional unless it is an aggregate that can not be NULL: `pick(coalesce(group_concat(:column), \"\"))`" : ""
        bad(term, "`#{term.name}` gives #{shown(got[:type], got[:optional])}, but `returns:` says #{shown(*want)}#{hint}")
      end

      def shown(type, optional) = ":#{type}#{'?' if optional}"
    end
  end
end
