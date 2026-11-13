# frozen_string_literal: true

module AxumDsl
  module Db
    # A small immutable relation IR and the renderer from it to ONE deterministic SQLite statement. It is pure:
    # no reader, no Prism, no I/O. A later step builds the IR from parsed DSL source and hands the SQL to the
    # statement pipeline, so this file is the contract between the two. Needs `axum_dsl` loaded first (errors are
    # AxumDsl::CompileError; the caller adds the file and line).
    #
    # The schema: anything with `schema[table_name]` that answers an ordered Array of
    # `{ name:, type:, optional: }` (name String or Symbol, type a Symbol such as :i64, :string, :f64, :bool), or nil
    # when the table is unknown. A plain Hash works, and so does the registry's `tables`. A column is checked
    # against it whenever the table is known; the table must be known where a statement needs its column list
    # (default selection, insert, update, touch, derived types).
    #
    # Building (every value is frozen; `where`, `join`, ... answer a new Relation):
    #   Rel.from(table, table_alias: nil)             # a Relation
    #   relation.where(*predicates)                   # ANDed, insertion order
    #   relation.join(Join.new(table, table_alias, left_col, right_col, discriminator_hash_or_nil, left_outer))
    #                                                 # left_outer true is LEFT OUTER JOIN: its columns are optional
    #   relation.selecting(*items)                    # an item is a value or Sel.new(value, name); none = all columns
    #   relation.order_by(*terms)                     # Order.new(value, desc, nocase)
    #   relation.limited(integer_or_Arg)
    #   relation.last_of(integer_or_Arg)              # `last(n)`: the last n rows of the order, handed back in that order
    #   relation.offset_by(integer_or_Arg)            # needs a limit
    #   relation.distinctly                           # SELECT DISTINCT
    # Values:     Arg.new(name)  Lit.new(String|Integer|true|false|nil)  Col.new(table_or_alias_or_nil, column)
    #             Fn.new(name, args, type)  Raw.new(sql, type_or_nil)  Expr.new(template, type, table_or_nil)
    #             Fn.new("group_concat", [col], nil)  an aggregate: only the value of a pick (one row, NULL over no rows;
    #             inside a coalesce it is never NULL, and then the pick is not optional)
    #             InIds.new(arg_name)  a Relation (a one-column subquery)   NOW (the Expr that stamps the time)
    # Predicates: Eq.new(left, right)  Cmp.new(left, op, right)  Null.new(col)  NotNull.new(col)
    #             Not.new(eq)  Or.new(a, b)  RawPred.new(sql)  Exists.new(rel, join, negate)
    #             OrWhere.new(left_preds, right_preds)   # Rails' `or`: (left AND ...) OR (right AND ...)
    # Terminals, each answers `{ sql:, returns: }`; `returns` is one of
    #   { shape: :one | :list, fields: [{ name:, type:, optional: }] }    first, all
    #   { shape: :scalar, type:, optional: }                              pick, count, exists, insert returning
    #   { shape: :execute }                                               insert, update, touch, delete
    #   Rel.first(rel, schema)  Rel.all(rel, schema)  Rel.pick(rel, value, schema)  Rel.count(rel, schema)
    #   Rel.exists(rel, schema)  Rel.insert(table, values, schema, returning: nil, on_duplicate: nil)
    #   Rel.insert_from(table, source_rel, values, schema, on_duplicate: nil)  # INSERT ... SELECT, see `insert_from`
    #   Rel.update(rel, values, schema, stamp: true)  Rel.touch(rel, schema)  Rel.delete(rel, schema)
    #   Rel.destroy(rel, plan, schema)  # an ordered Array of { sql:, returns: }, see `destroy`
    # `values` for insert and update is an ordered Hash of column => value.
    module Rel
      Arg = Struct.new(:name)
      Lit = Struct.new(:value)
      # table is a table name or alias; nil means the relation's own table (its alias when it has one).
      Col = Struct.new(:table, :column)
      Fn = Struct.new(:name, :args, :type)
      Raw = Struct.new(:sql, :type)
      # template is SQL in which `{t}` stands for the table name or alias (table, or the relation's own table).
      # binds (or nil) maps each `:name` the template writes to the value that takes its place.
      # name is the declared `expr` it came from, or nil (the type graph names it).
      Expr = Struct.new(:template, :type, :table, :binds, :name)
      InIds = Struct.new(:arg)
      Sel = Struct.new(:value, :name)
      Order = Struct.new(:value, :desc, :nocase)
      Join = Struct.new(:table, :table_alias, :left, :right, :discriminator, :left_outer)

      Eq = Struct.new(:left, :right)
      Cmp = Struct.new(:left, :op, :right)
      Null = Struct.new(:left)
      NotNull = Struct.new(:left)
      Not = Struct.new(:eq)
      Or = Struct.new(:a, :b)
      # Rails' `or`: `left` and `right` are Arrays of predicates, each side ANDed, the sides joined with OR.
      OrWhere = Struct.new(:left, :right)
      # EXISTS over `rel` (a relation of the association's table with its own conditions), correlated by `join`
      # (the Join `joins` would make for the association); `negate` is NOT EXISTS.
      Exists = Struct.new(:rel, :join, :negate)
      RawPred = Struct.new(:sql)
      # A :bool Expr as the whole condition (parenthesised); `negate` is NOT.
      Cond = Struct.new(:value, :negate)

      Relation = Struct.new(:table, :table_alias, :joins, :predicates, :selection, :orders, :limit, :offset, :distinct, :tail) do
        def with(**changes)
          copy = dup
          changes.each { |k, v| copy[k] = v }
          copy.freeze
        end

        def where(*preds) = with(predicates: (predicates + preds).freeze)
        def join(j) = with(joins: (joins + [j]).freeze)
        def selecting(*items) = with(selection: items.freeze)
        def order_by(*terms) = with(orders: (orders + terms).freeze)
        def limited(n) = with(limit: n)
        def last_of(n) = with(limit: n, tail: true)
        def offset_by(n) = with(offset: n)
        def distinctly = with(distinct: true)
      end

      # The time stamp SQLite writes into created_at and updated_at.
      NOW = Expr.new("strftime('%Y-%m-%d %H:%M:%f', 'now')", :string, nil).freeze

      OPS = %w[> >= < <= <> LIKE].freeze

      # What one statement is rendered against: the relation, the schema, whether any join makes columns
      # qualified, and the table behind each name or alias the relation uses.
      Ctx = Struct.new(:rel, :schema, :joined, :refs)

      module_function

      def from(table, table_alias: nil)
        Relation.new(table.to_s, table_alias&.to_s, [].freeze, [].freeze, nil, [].freeze, nil, nil, false, false).freeze
      end

      def first(rel, schema)
        err("last gives a list; it can not be the first row") if rel.tail
        rows(rel.with(limit: 1), schema, :one)
      end

      def all(rel, schema)
        rows(rel, schema, :list)
      end

      # One optional scalar: the value given, from the first row. An AGGREGATE value (`group_concat`, alone or inside
      # `coalesce`) is read over the whole relation, which always gives exactly one row, so it takes no order, limit,
      # offset or distinct and is optional only when its own type says so: `coalesce(group_concat(x), "")` never is.
      def pick(rel, value, schema)
        ctx = build_ctx(rel, schema)
        type, optional = type_of(value, ctx)
        if aggregate?(value)
          err("a pick of an aggregate takes a relation without order, limit, offset or distinct (it reads the whole relation)") unless rel.orders.empty? && rel.limit.nil? && rel.offset.nil? && !rel.distinct && !rel.tail
          return { sql: select_sql(ctx, [value_sql(value, ctx)]), returns: { shape: :scalar, type: type, optional: optional } }
        end
        sql = select_sql(ctx, [value_sql(value, ctx)], limit: 1)
        { sql: sql, returns: { shape: :scalar, type: type, optional: true } }
      end

      # Whether a value is an aggregate over the whole relation: `group_concat(...)`, or a `coalesce` whose first argument is.
      def aggregate?(value)
        return false unless value.is_a?(Fn)

        value.name.to_s.casecmp?("group_concat") || (value.name.to_s.casecmp?("coalesce") && aggregate?(value.args.first))
      end

      def count(rel, schema)
        ctx = build_ctx(rel, schema)
        err("count takes a relation without order or limit") unless rel.orders.empty? && rel.limit.nil?
        err("count takes a relation without distinct") if rel.distinct
        { sql: select_sql(ctx, ["COUNT(*)"]), returns: { shape: :scalar, type: :i64, optional: false } }
      end

      def exists(rel, schema)
        ctx = build_ctx(rel, schema)
        err("exists takes a relation without order or limit") unless rel.orders.empty? && rel.limit.nil?
        err("exists takes a relation without distinct") if rel.distinct
        { sql: "SELECT EXISTS(#{select_sql(ctx, ['1'])})", returns: { shape: :scalar, type: :bool, optional: false } }
      end

      # created_at and updated_at are appended with NOW (created_at first) when the table has them and the caller
      # gave no value.
      def insert(table, values, schema, returning: nil, on_duplicate: nil)
        table = table.to_s
        ctx = build_ctx(from(table), schema)
        cols = table_columns(schema, table)
        given = values.to_h { |k, v| [k.to_s, v] }
        given.each_key { |k| column_of(cols, table, k) }
        %w[created_at updated_at].each { |s| given[s] = NOW if has_column?(cols, s) && !given.key?(s) }
        err("insert into `#{table}` needs at least one value") if given.empty?
        sql = "#{insert_into(on_duplicate)} #{table} (#{given.keys.join(', ')}) VALUES (#{given.values.map { |v| value_sql(v, ctx) }.join(', ')})"
        returns = { shape: :execute }
        if returning
          returns = { shape: :scalar, type: column_of(cols, table, returning.to_s)[:type], optional: false }
          sql += " RETURNING #{returning}"
        end
        { sql: sql, returns: returns }
      end

      # INSERT ... SELECT: `source` is a relation (no selection) whose rows feed the insert, and each value of `values`
      # is rendered against it, so a Col is a column of the source. The stamps are added as `insert` adds them.
      def insert_from(table, source, values, schema, on_duplicate: nil)
        table = table.to_s
        cols = table_columns(schema, table)
        given = values.to_h { |k, v| [k.to_s, v] }
        given.each_key { |k| column_of(cols, table, k) }
        err("insert_from takes a relation without a selection: the values come from the pairs") if source.selection
        err("insert_from takes a relation without last") if source.tail
        %w[created_at updated_at].each { |s| given[s] = NOW if has_column?(cols, s) && !given.key?(s) }
        err("insert_from into `#{table}` needs at least one value") if given.empty?
        ctx = build_ctx(source, schema)
        sql = "#{insert_into(on_duplicate)} #{table} (#{given.keys.join(', ')}) #{select_sql(ctx, given.values.map { |v| value_sql(v, ctx) })}"
        { sql: sql, returns: { shape: :execute } }
      end

      def insert_into(on_duplicate)
        return "INSERT INTO" unless on_duplicate

        err("on_duplicate: takes :skip, not #{on_duplicate.inspect}") unless on_duplicate == :skip
        "INSERT OR IGNORE INTO"
      end

      # The stamp (last) is added only when the table has updated_at, the caller did not set it and stamp is true.
      # Like Rails' `update`, it moves updated_at only when a value changes: `updated_at = CASE WHEN col IS NOT value
      # [OR ...] THEN NOW ELSE updated_at END` (SQLite reads every right-hand side from the row as it was, and IS NOT
      # compares NULL as a value).
      def update(rel, values, schema, stamp: true)
        ctx = build_ctx(rel, schema)
        err("an update can not have joins") if ctx.joined
        cols = table_columns(schema, rel.table)
        sets = values.to_h { |k, v| [k.to_s, v] }
        sets.each_key { |k| column_of(cols, rel.table, k) }
        err("update of `#{rel.table}` sets nothing") if sets.empty?
        sets.each do |k, v|
          err("column `#{k}` of `#{rel.table}` is NOT NULL, so it can not be set to nil") if v.is_a?(Lit) && v.value.nil? && !column_of(cols, rel.table, k)[:optional]
        end
        set_sql = ->(v) { v.is_a?(Lit) && v.value.nil? ? "NULL" : value_sql(v, ctx) }
        assignments = sets.map { |k, v| "#{k} = #{set_sql.call(v)}" }
        if stamp && has_column?(cols, "updated_at") && !sets.key?("updated_at")
          changed = sets.map { |k, v| "#{k} IS NOT #{set_sql.call(v)}" }.join(" OR ")
          assignments << "updated_at = CASE WHEN #{changed} THEN #{value_sql(NOW, ctx)} ELSE updated_at END"
        end
        assignments = assignments.join(", ")
        { sql: ["UPDATE #{table_ref(rel.table, rel.table_alias)} SET #{assignments}", where_sql(ctx)].compact.join(" "),
          returns: { shape: :execute } }
      end

      def touch(rel, schema)
        err("`#{rel.table}` has no updated_at to touch") unless has_column?(table_columns(schema, rel.table), "updated_at")
        update(rel, { "updated_at" => NOW }, schema, stamp: false)
      end

      def delete(rel, schema)
        ctx = build_ctx(rel, schema)
        err("a delete can not have joins") if ctx.joined
        { sql: ["DELETE FROM #{table_ref(rel.table, rel.table_alias)}", where_sql(ctx)].compact.join(" "),
          returns: { shape: :execute } }
      end

      # plan is an Array of `{ table:, fk:, discriminator: { col => 'Value' } or nil, mode: :destroy | :delete_all,
      # dependents: [...] }`. For each dependent in order, a :destroy one first emits its own dependents
      # (recursively) and then its own DELETE; a :delete_all one emits its DELETE; the root's DELETE is last. A
      # dependent's rows are `fk = value` when its parent's rows are exactly `id = value`, else
      # `fk IN (SELECT id FROM parent WHERE parent's conditions)`; the discriminator comes first.
      def destroy(rel, plan, schema)
        ctx = build_ctx(rel, schema)
        err("a destroy can not have joins") if ctx.joined
        rows = { sql: conj_sql(rel.predicates, ctx), pk: pk_value(rel, ctx) }
        out = []
        destroy_dependents(rel.table, rows, plan, out)
        out << { sql: delete_from(rel.table, rows[:sql]), returns: { shape: :execute } }
      end

      # --- rendering --------------------------------------------------------------------------------------------

      def err(message) = raise(AxumDsl::CompileError, message)

      def rows(rel, schema, shape)
        ctx = build_ctx(rel, schema)
        items = selection_items(ctx)
        err("an aggregate (group_concat) can only be the value of a pick") if items.any? { |s| aggregate?(s.value) }
        sql = rel.tail ? last_sql(ctx, items) : select_sql(ctx, items.map { |s| item_sql(s, ctx) })
        fields = items.map do |s|
          type, optional = type_of(s.value, ctx)
          { name: item_name(s), type: type, optional: optional }
        end
        # sources: field name => the type graph ids its type comes from (the AST-level record of "takes its type from")
        { sql: sql, returns: { shape: shape, fields: fields }, sources: items.to_h { |s| [item_name(s), source_ids(s.value, ctx)] } }
      end

      # `last(n)`: the inner query takes the last n rows by reversing every order term, the outer one puts them back in the
      # declared order. Each term is selected in the inner query under a private alias (_o1, ...), so an expression or
      # a joined column sorts in the outer query too; the aliases are not in the outer selection.
      def last_sql(ctx, items)
        rel = ctx.rel
        err("last needs an order to take the last rows of: `order(:created_at, :id).last(40)`") if rel.orders.empty?
        err("last can not be combined with distinct") if rel.distinct
        err("last can not be combined with offset") if rel.offset
        keys = rel.orders.each_with_index.map { |t, i| "#{value_sql(t.value, ctx)} AS _o#{i + 1}" }
        reversed = rel.orders.map { |t| Order.new(t.value, !t.desc, t.nocase) }.freeze
        inner = select_sql(Ctx.new(rel.with(orders: reversed), ctx.schema, ctx.joined, ctx.refs), items.map { |s| item_sql(s, ctx) } + keys)
        outer = rel.orders.each_with_index.map { |t, i| ["_o#{i + 1}", (t.nocase ? "COLLATE NOCASE" : nil), (t.desc ? "DESC" : nil)].compact.join(" ") }
        "SELECT #{items.map { |s| item_name(s) }.join(', ')} FROM (#{inner}) ORDER BY #{outer.join(', ')}"
      end

      def build_ctx(rel, schema)
        refs = {}
        [[rel.table, rel.table_alias], *rel.joins.map { |j| [j.table.to_s, j.table_alias&.to_s] }].each do |table, al|
          ref = al || table
          err("table `#{table}` appears twice in one relation; give one of them an alias") if refs.key?(ref)
          refs[ref] = table
        end
        Ctx.new(rel, schema, !rel.joins.empty?, refs)
      end

      def select_sql(ctx, columns, limit: ctx.rel.limit)
        rel = ctx.rel
        ["SELECT #{'DISTINCT ' if rel.distinct}#{columns.join(', ')}",
         "FROM #{table_ref(rel.table, rel.table_alias)}",
         *rel.joins.map { |j| join_sql(j, ctx) },
         where_sql(ctx),
         order_sql(ctx),
         limit_sql(limit, rel.offset)].compact.join(" ")
      end

      def subquery_sql(rel, schema)
        ctx = build_ctx(rel, schema)
        items = selection_items(ctx)
        err("a subquery selects exactly one column") unless items.size == 1
        err("a subquery can not use last") if rel.tail
        select_sql(ctx, items.map { |s| item_sql(s, ctx) })
      end

      def table_ref(table, table_alias) = table_alias ? "#{table} AS #{table_alias}" : table

      def join_sql(join, ctx)
        ref = join.table_alias || join.table
        on = ["#{col_sql(join.left, ctx)} = #{col_sql(join.right, ctx)}"]
        (join.discriminator || {}).each { |c, v| on << "#{col_sql(Col.new(ref, c), ctx)} = #{lit_sql(v)}" }
        "#{join.left_outer ? 'LEFT OUTER JOIN' : 'JOIN'} #{table_ref(join.table, join.table_alias)} ON #{on.join(' AND ')}"
      end

      def where_sql(ctx)
        return nil if ctx.rel.predicates.empty?

        "WHERE #{conj_sql(ctx.rel.predicates, ctx)}"
      end

      # Predicates ANDed; an `or` among several is parenthesised.
      def conj_sql(preds, ctx)
        preds.map { |p| p.is_a?(OrWhere) && preds.size > 1 ? "(#{pred_sql(p, ctx)})" : pred_sql(p, ctx) }.join(' AND ')
      end

      def order_sql(ctx)
        return nil if ctx.rel.orders.empty?

        terms = ctx.rel.orders.map do |t|
          [value_sql(t.value, ctx), (t.nocase ? "COLLATE NOCASE" : nil), (t.desc ? "DESC" : nil)].compact.join(" ")
        end
        "ORDER BY #{terms.join(', ')}"
      end

      def limit_sql(limit, offset = nil)
        err("an offset needs a limit") if offset && limit.nil?
        parts = [(bound_sql("limit", limit) if limit), (bound_sql("offset", offset) if offset)].compact
        parts.empty? ? nil : parts.join(" ")
      end

      def bound_sql(word, value)
        case value
        when Integer then "#{word.upcase} #{value}"
        when Arg then "#{word.upcase} :#{value.name}"
        else err("a #{word} is an integer or an argument, not #{value.inspect}")
        end
      end

      # No selection means every column of the root table, in schema order.
      def selection_items(ctx)
        return ctx.rel.selection.map { |i| i.is_a?(Sel) ? i : Sel.new(i, nil) } if ctx.rel.selection

        table_columns(ctx.schema, ctx.rel.table).map { |c| Sel.new(Col.new(nil, c[:name]), nil) }
      end

      def item_name(item)
        return item.name.to_s if item.name
        return item.value.column.to_s if item.value.is_a?(Col)

        err("a selected #{item.value.class.name.split('::').last} needs a name")
      end

      def item_sql(item, ctx)
        name = item_name(item)
        expr = value_sql(item.value, ctx)
        item.value.is_a?(Col) && !ctx.joined && name == item.value.column.to_s ? expr : "#{expr} AS #{name}"
      end

      def pred_sql(pred, ctx)
        case pred
        when Eq then eq_sql(pred, ctx, false)
        when Not
          err("not applies to an equality only") unless pred.eq.is_a?(Eq)
          eq_sql(pred.eq, ctx, true)
        when Cmp
          err("unknown comparison `#{pred.op}`; use one of #{OPS.join(' ')}") unless OPS.include?(pred.op.to_s)
          "#{value_sql(pred.left, ctx)} #{pred.op} #{value_sql(pred.right, ctx)}"
        when Null then "#{value_sql(pred.left, ctx)} IS NULL"
        when NotNull then "#{value_sql(pred.left, ctx)} IS NOT NULL"
        when Or then "(#{pred_sql(pred.a, ctx)} OR #{pred_sql(pred.b, ctx)})"
        when OrWhere then "(#{conj_sql(pred.left, ctx)}) OR (#{conj_sql(pred.right, ctx)})"
        when Exists then exists_sql(pred, ctx)
        when Cond then "#{pred.negate ? "NOT " : ""}(#{value_sql(pred.value, ctx)})"
        when RawPred then pred.sql
        else err("not a predicate: #{pred.inspect}")
        end
      end

      # EXISTS (SELECT 1 FROM target WHERE target.fk = outer.key [AND discriminator] [AND conditions]). Every column is
      # qualified; the target is aliased `<table>_exists` when the enclosing relation already uses its name.
      def exists_sql(pred, ctx)
        rel = pred.rel
        join = pred.join
        al = ctx.refs.key?(rel.table) ? "#{rel.table}_exists" : nil
        ref = al || rel.table
        corr = [Eq.new(Col.new(ref, join.left.column), join.right)]
        (join.discriminator || {}).each { |c, v| corr << Eq.new(Col.new(ref, c), Lit.new(v)) }
        inner = rel.with(table_alias: al, predicates: (corr + rel.predicates).freeze)
        refs = ctx.refs.merge(build_ctx(inner, ctx.schema).refs)
        "#{'NOT ' if pred.negate}EXISTS (#{select_sql(Ctx.new(inner, ctx.schema, true, refs), ['1'])})"
      end

      def eq_sql(eq, ctx, negate)
        left = value_sql(eq.left, ctx)
        right = eq.right
        right = nil if right.is_a?(Lit) && right.value.nil?
        within = negate ? "NOT IN" : "IN"
        case right
        when nil then "#{left} IS#{negate ? ' NOT' : ''} NULL"
        when Array
          err("an empty list can not be compared with IN") if right.empty?
          "#{left} #{within} (#{right.map { |v| value_sql(v, ctx) }.join(', ')})"
        when Relation then "#{left} #{within} (#{subquery_sql(right, ctx.schema)})"
        when InIds then "#{left} #{within} (SELECT value FROM json_each('[' || :#{right.arg} || ']'))"
        else "#{left} #{negate ? '<>' : '='} #{value_sql(right, ctx)}"
        end
      end

      def value_sql(value, ctx)
        case value
        when Arg then ":#{value.name}"
        when Lit then lit_sql(value.value)
        when Col then col_sql(value, ctx)
        when Fn then "#{value.name.to_s.casecmp?('coalesce') ? 'COALESCE' : value.name}(#{value.args.map { |a| value_sql(a, ctx) }.join(', ')})"
        when Raw then value.sql
        when Expr then expr_sql(value, ctx)
        when Relation then "(#{subquery_sql(value, ctx.schema)})"
        else err("not a usable value here: #{value.inspect}")
        end
      end

      # The template with `{t}` as the table and each bound `:name` replaced by the value's SQL.
      def expr_sql(expr, ctx)
        sql = expr.template.gsub("{t}") { (expr.table || ctx.rel.table_alias || ctx.rel.table).to_s }
        return sql if expr.binds.nil? || expr.binds.empty?

        Sql.placeholders(sql).select { |p| p.kind == :named && expr.binds.key?(p.name) }.reverse_each do |p|
          sql = "#{sql[0, p.offset]}#{value_sql(expr.binds.fetch(p.name), ctx)}#{sql[(p.offset + 1 + p.name.size)..]}"
        end
        sql
      end

      def lit_sql(value)
        case value
        when String then "'#{value.gsub("'", "''")}'"
        when Integer then value.to_s
        when true then "1"
        when false then "0"
        else err("a literal is a string, an integer or a boolean, not #{value.inspect}; compare with nil through Eq")
        end
      end

      # A column is qualified only when the relation has a join.
      def col_sql(col, ctx)
        ref = (col.table || ctx.rel.table_alias || ctx.rel.table).to_s
        table = ctx.refs[ref] or err("unknown table or alias `#{ref}` in this relation")
        column_of(table_columns(ctx.schema, table), table, col.column.to_s) if ctx.schema[table]
        ctx.joined ? "#{ref}.#{col.column}" : col.column.to_s
      end

      # [type, optional] of a selected value.
      def type_of(value, ctx)
        case value
        when Col
          ref = (value.table || ctx.rel.table_alias || ctx.rel.table).to_s
          table = ctx.refs[ref] or err("unknown table or alias `#{ref}` in this relation")
          c = column_of(table_columns(ctx.schema, table), table, value.column.to_s)
          [c[:type], c[:optional] || left_joined?(ctx, ref)]
        when Fn
          if value.name.to_s.casecmp?("coalesce")
            err("coalesce takes at least two arguments") if value.args.size < 2
            [type_of(value.args.first, ctx).first, false]
          elsif value.name.to_s.casecmp?("group_concat")
            err("group_concat takes one column") unless value.args.size == 1
            type_of(value.args.first, ctx)
            [:string, true] # NULL over no rows
          else
            value.type ? [value.type.to_sym, false] : err("function `#{value.name}` in a selection needs a type")
          end
        when Raw, Expr
          err("a Raw or Expr in a selection needs a type") unless value.type
          [value.type.to_sym, value.is_a?(Expr) && !value.table.nil? && left_joined?(ctx, value.table.to_s)]
        when Lit
          case value.value
          when String then [:string, false]
          when Integer then [:i64, false]
          when true, false then [:bool, false]
          else err("a literal in a selection is a string, an integer or a boolean")
          end
        else err("can not type #{value.inspect}")
        end
      end

      # Where a selected value's type comes from, as type graph ids: the columns it reads (`column:rooms.id`, the table behind an
      # alias resolved) and the declared exprs (`expr:is_current`).
      def source_ids(value, ctx)
        case value
        when Col
          ref = (value.table || ctx.rel.table_alias || ctx.rel.table).to_s
          ["column:#{ctx.refs[ref] || ref}.#{value.column}"]
        when Fn then value.args.flat_map { |a| source_ids(a, ctx) }
        when Expr then value.name ? ["expr:#{value.name}"] : []
        else []
        end
      end

      # Whether a name or alias is a table of a LEFT OUTER JOIN, whose columns may be NULL.
      def left_joined?(ctx, ref) = ctx.rel.joins.any? { |j| j.left_outer && (j.table_alias || j.table).to_s == ref }

      # The schema's columns of a table, normalized to { name: String, type: Symbol, optional: Boolean }.
      def table_columns(schema, table)
        raw = schema[table.to_s] or err("the schema has no table `#{table}`")
        raw.map { |c| { name: c[:name].to_s, type: c[:type].to_sym, optional: c[:optional] ? true : false } }
      end

      def has_column?(cols, name) = cols.any? { |c| c[:name] == name }

      def column_of(cols, table, name)
        cols.find { |c| c[:name] == name } or err("table `#{table}` has no column `#{name}`")
      end

      # --- destroy ----------------------------------------------------------------------------------------------

      # The value when the root's rows are exactly `id = value`, else nil.
      def pk_value(rel, ctx)
        pred = rel.predicates.first
        return nil unless rel.predicates.size == 1 && pred.is_a?(Eq)
        return nil unless pred.left.is_a?(Col) && pred.left.column.to_s == "id"
        return nil unless [Arg, Lit].include?(pred.right.class) && !(pred.right.is_a?(Lit) && pred.right.value.nil?)

        value_sql(pred.right, ctx)
      end

      def destroy_dependents(parent_table, rows, plan, out)
        plan.each do |dep|
          table = dep[:table].to_s
          mode = dep[:mode]
          err("a dependent's mode is :destroy or :delete_all, not #{mode.inspect}") unless %i[destroy delete_all].include?(mode)
          kids = dep[:dependents] || []
          err("`#{table}` is :delete_all, so it can not have dependents") if mode == :delete_all && !kids.empty?
          where = rows[:sql].empty? ? "" : " WHERE #{rows[:sql]}"
          conds = (dep[:discriminator] || {}).map { |c, v| "#{c} = #{lit_sql(v)}" }
          conds << (rows[:pk] ? "#{dep[:fk]} = #{rows[:pk]}" : "#{dep[:fk]} IN (SELECT id FROM #{parent_table}#{where})")
          own = { sql: conds.join(" AND "), pk: nil }
          destroy_dependents(table, own, kids, out) if mode == :destroy
          out << { sql: delete_from(table, own[:sql]), returns: { shape: :execute } }
        end
      end

      def delete_from(table, cond) = cond.empty? ? "DELETE FROM #{table}" : "DELETE FROM #{table} WHERE #{cond}"
    end
  end
end
