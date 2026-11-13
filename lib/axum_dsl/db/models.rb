# frozen_string_literal: true

module AxumDsl
  module Db
    # The model registry: the models a file declares (`model :Room, table: :rooms do ... end`), their associations
    # and scopes, and the named expressions (`expr`), as the reader keeps them in the IR under "models" and
    # "exprs" (docs/database.md, "Models"). Nothing is emitted from them; the relation chains to come read them
    # through here.
    #
    # An association is resolved when it is asked for (`association`), against the declared tables and models, and
    # a declaration that points at nothing raises Unresolved with a message naming the model, the association and
    # the missing thing (the reader runs every one at the end of the read and puts the message on the declaration).
    #
    #   association(model, name) => { name:, kind: :has_many | :has_one | :belongs_to, target_table:, target_model:,
    #                                 foreign_key:, owner_key:, discriminator: { column => model name } or nil,
    #                                 through: association name or nil, source: nil or the far association a
    #                                 through goes to, dependent: :destroy | :delete_all or nil,
    #                                 conditions: { column => literal } of a `has_one`'s `-> { where(...) }`, or nil,
    #                                 derived: { "from" =>, "at" => } where a declaration (`has_one_attached`) derived it, or nil }
    #
    # `foreign_key` is the column that holds the reference: on the target's table for has_many and has_one, on the
    # model's own table for belongs_to. `owner_key` is the column of the model's table it matches: "id" for has_many
    # and has_one, the foreign key itself for belongs_to (the target's "id" is the other end). A through association
    # has neither, nor a discriminator: its keys are the two associations it goes through. `target_model` is nil when
    # no `model` owns the target table.
    class Models
      # The relation operations a scope may not be named after, because it would hide the operation.
      OPERATIONS = %w[where joins left_joins select order limit first all pick count exists insert update update_all touch delete destroy where_not where_exists where_not_exists or last offset distinct insert_from].freeze

      # A declaration that does not resolve. `word` is the misspelt name and `from` the valid ones, for a "did you
      # mean" hint.
      class Unresolved < StandardError
        attr_reader :word, :from

        def initialize(message, word: nil, from: nil)
          super(message)
          @word = word
          @from = from
        end
      end

      # The registry for an IR's "models" and "exprs" entries over a Db::Schema.
      def self.from_ir(models, exprs, schema)
        registry = new(schema)
        models.to_a.each { |m| registry.add_model(m) }
        exprs.to_a.each { |e| registry.add_expr(e) }
        registry
      end

      attr_reader :schema

      def initialize(schema)
        @schema = schema
        @models = {}
        @exprs = {}         # the top-level exprs, name => expr
        @model_exprs = {}   # model => { name => expr }
        @concern_exprs = {} # concern => { name => expr }
        @resolved = {}
      end

      def add_model(model)
        @models[model["name"].to_s] = model
      end

      def add_expr(expr)
        found = { name: expr["name"], type: expr["type"], sql: expr["sql"], of: expr["of"], **(expr["args"] ? { args: expr["args"] } : {}),
                  **(expr["model"] ? { model: expr["model"] } : {}), **(expr["concern"] ? { concern: expr["concern"] } : {}) }.freeze
        if expr["model"] then (@model_exprs[expr["model"]] ||= {})[expr["name"].to_s] = found
        elsif expr["concern"] then (@concern_exprs[expr["concern"]] ||= {})[expr["name"].to_s] = found
        else @exprs[expr["name"].to_s] = found
        end
      end

      def model_names = @models.keys

      def model?(name) = @models.key?(name.to_s)

      # The table a model owns, or nil when it names none or is not declared.
      def table(model) = @models[model.to_s]&.fetch("table")

      # The name of the one model that owns a table, or nil when none or several do (models of one table: STI).
      def model_for_table(table)
        owners = @models.values.select { |m| m["table"] == table.to_s }
        owners.size == 1 ? owners.first["name"] : nil
      end

      # One association, resolved, or nil when the model or the association is not declared. Raises Unresolved when
      # the declaration points at nothing.
      def association(model, name)
        m = @models[model.to_s] or return nil
        decl = m["associations"].find { |a| a["name"] == name.to_s } or return nil
        @resolved[[m["name"], decl["name"]]] ||= resolve(m, decl)
      end

      # The model's associations, resolved, in declaration order.
      def associations(model)
        (@models[model.to_s]&.fetch("associations") || []).map { |a| association(model, a["name"]) }
      end

      # One scope as `{ name:, params: [names], body: the lambda's body node, line: }`, or nil.
      def scope(model, name)
        s = @models[model.to_s]&.fetch("scopes")&.find { |x| x["name"] == name.to_s } or return nil
        { name: s["name"], params: s["params"], body: s["body"], line: s["line"] }
      end

      # The names of the model's scopes, in declaration order.
      def scope_names(model) = (@models[model.to_s]&.fetch("scopes") || []).map { |s| s["name"] }

      # One `has_one_attached` of the model as `{ "name", "from", "at" }`, or nil.
      def attached(model, name) = @models[model.to_s]&.fetch("attached", nil)&.find { |a| a["name"] == name.to_s }

      # The names of the model's `has_one_attached`s.
      def attached_names(model) = (@models[model.to_s]&.fetch("attached", nil) || []).map { |a| a["name"] }

      # A named expression as `{ name:, type:, sql:, of: }` (`of` is the table placeholder's name, or nil; `model:` or `concern:` name the
      # owner of one declared in a `model` or a `concern`), or nil. A relation of a model finds, in this order: the model's own expr, an
      # expr of a concern the model includes (in include order), a top-level expr. Two included concerns that both provide a name are
      # refused where the model includes them (check_includes in the reader), so the first found is the only one.
      def expr(name, model: nil)
        key = name.to_s
        (model && @model_exprs.dig(model.to_s, key)) || included_expr(model, key) || @exprs[key]
      end

      # The names `expr` finds for the model, in order of precedence: its own, those of the concerns it includes, the top level's.
      def expr_names(model: nil)
        own = model ? (@model_exprs[model.to_s]&.keys || []) : []
        own + includes(model).flat_map { |c| @concern_exprs[c]&.keys || [] } + @exprs.keys
      end

      # The concerns a model includes, in order.
      def includes(model) = model ? (@models[model.to_s]&.fetch("includes", nil) || []) : []

      def concern?(name) = @concern_exprs.key?(name.to_s)

      def concern_names = @concern_exprs.keys

      # The exprs of a concern, name => expr.
      def concern_exprs(name) = @concern_exprs[name.to_s] || {}

      # The columns an expr reads from its table: the `{t}.column` of its sql.
      def expr_columns(found)
        return [] unless found[:of]

        found[:sql].scan(/\{#{Regexp.escape(found[:of])}\}\.([A-Za-z_][A-Za-z0-9_]*)/).flatten.uniq
      end

      # What to append to a "no such expr" refusal when a concern the model does not include has one of that name, or "".
      def expr_not_found_hint(name, model)
        concern = @concern_exprs.find { |_, exprs| exprs.key?(name.to_s) }&.first or return ""
        model ? "; `#{name}` is in concern `#{concern}`; add `include :#{concern}` to `#{model}`" : "; `#{name}` is in concern `#{concern}`"
      end

      # What `destroy` of a model deletes besides the row, in the shape Db::Rel.destroy takes: for each
      # `dependent:` association in declaration order `{ table:, fk:, discriminator:, mode:, dependents: }`, a
      # :destroy one carrying the plan of its own model. A cycle of `dependent: :destroy` is refused.
      def destroy_plan(model, path = [])
        name = model.to_s
        refuse("no model \"#{name}\" is declared", word: name, from: @models.keys) unless @models.key?(name)
        here = path + [name]
        associations(name).filter_map do |a|
          next unless a[:dependent]

          dependents = []
          if a[:dependent] == :destroy && a[:target_model]
            if here.include?(a[:target_model])
              refuse("model \"#{name}\" #{a[:kind]} :#{a[:name]}, dependent: :destroy, goes round in a circle (#{(here + [a[:target_model]]).join(' -> ')})")
            end
            dependents = destroy_plan(a[:target_model], here)
          end
          { table: a[:target_table], fk: a[:foreign_key], discriminator: a[:discriminator], mode: a[:dependent], dependents: dependents }
        end
      end

      private

      def refuse(message, word: nil, from: nil) = raise(Unresolved.new(message, word: word, from: from))

      # The expr of the first concern the model includes that has the name, or nil.
      def included_expr(model, key)
        includes(model).each do |c|
          found = @concern_exprs.dig(c, key) and return found
        end
        nil
      end

      def resolve(model, decl)
        return resolve_through(model, decl) if decl["through"]

        who = who_of(model, decl)
        table, target = target_of(model, decl, who)
        if decl["kind"] == "belongs_to"
          fk = decl["foreign_key"] || "#{decl['name']}_id"
          require_column(model["table"], fk, who, decl["foreign_key"] ? "" : "; the foreign key is `#{fk}` unless `foreign_key:` says otherwise")
          return build(decl, target_table: table, target_model: target, foreign_key: fk, owner_key: fk)
        end

        discriminator = nil
        if decl["as"]
          fk = "#{decl['as']}_id"
          type = "#{decl['as']}_type"
          require_column(table, type, who, "; `as: :#{decl['as']}` needs the columns `#{type}` and `#{fk}`")
          require_column(table, fk, who, "; `as: :#{decl['as']}` needs the columns `#{type}` and `#{fk}`")
          discriminator = { type => model["name"] }
        else
          fk = decl["foreign_key"] || "#{snake(model['name'])}_id"
          require_column(table, fk, who, decl["foreign_key"] ? "" : "; the foreign key is `#{fk}` unless `foreign_key:` says otherwise")
        end
        (decl["conditions"] || {}).each_key { |c| require_column(table, c, who, "; the condition lambda's `where` names columns of the target table") }
        build(decl, target_table: table, target_model: target, foreign_key: fk, owner_key: "id", discriminator: discriminator)
      end

      def build(decl, target_table:, target_model:, foreign_key: nil, owner_key: nil, discriminator: nil, source: nil)
        { name: decl["name"], kind: decl["kind"].to_sym, target_table: target_table, target_model: target_model,
          foreign_key: foreign_key, owner_key: owner_key, discriminator: discriminator, through: decl["through"], source: source,
          dependent: decl["dependent"]&.to_sym, conditions: decl["conditions"], **(decl["derived"] ? { derived: decl["derived"] } : {}) }
      end

      def who_of(model, decl) = "model \"#{model['name']}\" #{decl['kind']} :#{decl['name']}"

      # The table an association reads and the model that owns it: `model:` (and its table), else `table:`, else for a
      # has_many the association's own name (a plural, as a table is); a has_one or belongs_to must name one of them,
      # because the name is singular and nothing here inflects it.
      def target_of(model, decl, who)
        owner = nil
        note = ""
        if decl["model"]
          owner = @models[decl["model"]] or
            refuse("#{who}: `model: :#{decl['model']}` is not a declared model (declared: #{@models.keys.join(', ')})", word: decl["model"], from: @models.keys)
          table = decl["table"] || owner["table"] or
            refuse("#{who}: model \"#{decl['model']}\" names no table; give the association a `table:`")
        elsif decl["table"]
          table = decl["table"]
        elsif decl["kind"] == "has_many"
          table = decl["name"]
          note = "; a has_many without `table:` or `model:` reads its table from its name"
        else
          refuse("#{who}: name the target with `model:` or `table:` (the name `:#{decl['name']}` is not turned into a table)")
        end
        unless @schema.table?(table)
          names = @schema.tables.keys
          refuse("#{who}: table `#{table}` is not declared (#{names.empty? ? 'none is declared' : "declared: #{names.join(', ')}"})#{note}", word: table, from: names)
        end
        [table, owner ? owner["name"] : model_for_table(table)]
      end

      def resolve_through(model, decl)
        who = who_of(model, decl)
        names = model["associations"].map { |a| a["name"] }
        via = model["associations"].find { |a| a["name"] == decl["through"] } or
          refuse("#{who}: `through: :#{decl['through']}` is not an association of the model (declared: #{names.join(', ')})", word: decl["through"], from: names)
        refuse("#{who}: `through: :#{via['name']}` is itself a through association, which is not supported") if via["through"]
        far = association(model["name"], via["name"])[:target_model] or
          refuse("#{who}: `through: :#{via['name']}` reaches table `#{association(model['name'], via['name'])[:target_table]}`, which no `model` owns, so there is no model to take `:#{decl['name']}` from")
        far_decls = @models.fetch(far)["associations"]
        wanted = decl["source"] ? [decl["source"]] : [decl["name"], singular(decl["name"])].uniq # a derived through names its source
        source = far_decls.find { |a| wanted.include?(a["name"]) } or
          refuse("#{who}: model \"#{far}\", which `through: :#{via['name']}` goes through, has no association #{wanted.map { |w| ":#{w}" }.join(' or ')} (declared: #{far_decls.map { |a| a['name'] }.join(', ')})",
                 word: decl["name"], from: far_decls.map { |a| a["name"] })
        refuse("#{who}: `#{far}##{source['name']}` is itself a through association, which is not supported") if source["through"]
        far_assoc = association(far, source["name"])
        build(decl, target_table: far_assoc[:target_table], target_model: far_assoc[:target_model], source: source["name"])
      end

      def require_column(table, column, who, hint)
        columns = @schema.columns(table) or refuse("#{who}: table `#{table}` is not declared")
        return if columns.any? { |c| c[:name] == column }

        names = columns.map { |c| c[:name] }
        refuse("#{who}: table `#{table}` has no column `#{column}` (columns: #{names.join(', ')})#{hint}", word: column, from: names)
      end

      # "Account::Bot" is "bot": the foreign key of a has_many is the owner's demodulized, underscored name plus `_id`.
      def snake(name) = name.split("::").last.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase

      def singular(name)
        return "#{name.delete_suffix('ies')}y" if name.end_with?("ies")

        name.end_with?("s") && !name.end_with?("ss") ? name.delete_suffix("s") : name
      end
    end
  end
end
