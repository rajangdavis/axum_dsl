# frozen_string_literal: true

module AxumDsl
  # The reader's side of a `query` or `execute` (docs/database.md): the one place a statement becomes an entry of
  # srv["queries"], whichever way it is written. Written with `sql:` the entry is made at once. Written as a
  # relation (a block inside a `model` that names its table, read by Db::Chain) the entry is made in the same
  # place, in declaration order, with "sql" nil, and `check_relation_queries` fills the SQL in once every table,
  # model, scope and record is known; nothing downstream sees a difference (the entry has the same keys).
  module RelationQueries
    private

    # The tail every statement shares: the spelling is checked (exactly one of `sql:` and a block), the SQL
    # text's placeholders against `args:` (a relation's are checked when it is rendered), and the entry is pushed.
    # `relation` is the block node, or nil for `sql:`.
    def add_statement(srv, node, name, what, args, returns, sql, relation)
      if sql.nil? == relation.nil?
        both = sql ? "has both `sql:` and a block; write one" : "has neither `sql:` nor a block; write one"
        bad(node, "#{what} `#{name}` #{both}: `#{what} :#{name}, args: {...}, sql: \"SELECT ...\"` or " \
                  "`#{what} :#{name}, args: {...} do where(...) end` (a relation, inside a `model` that names its `table:`)")
      end
      if relation
        check_relation_block(node, what, name, relation)
      else
        bad(node, "`sql:` is empty") if sql.strip.empty?
        check_placeholders(node, what, name, sql, args)
      end
      entry = { "name" => name, "kind" => what, "args" => args.to_a, "sql" => sql,
                "at" => "#{AxumDsl.file_of(node) || @path}:#{node.location.start_line}", **located(node) }
      if what == "query"
        entry["returns"] = returns
      else
        entry["shape"] = "execute"
        entry["rtype"] = "i64"
      end
      srv["queries"] << entry
      (@query_nodes ||= {})[name] = node
      (@flags["queries"] ||= {})[name] = entry
      # `records_at` is how many records are declared by this spot, where a record this relation derives is placed.
      (@relation_queries ||= {})[name] = { node: node, model: @declaring_model, body: relation.body, entry: entry,
                                           records_at: srv["records"].size } if relation
    end

    def check_relation_block(node, what, name, relation)
      model = @declaring_model
      unless model
        bad(node, "#{what} `#{name}` is written as a relation, which belongs in a `model :Name, table: :a_declared_table do ... end`; " \
                  "at the top level give it `sql:`")
      end
      if @models[model]["table"].nil?
        bad(node, "#{what} `#{name}` is a relation, so model \"#{model}\" names its table: `model :#{model}, table: :a_declared_table`; or give the statement `sql:`")
      end
      bad(relation.parameters, "the block of #{what} `#{name}` takes no parameters") if relation.parameters
      bad(relation, "#{what} `#{name}` has an empty block; write the relation, such as `where(id: arg(:id))`") if relation.body.nil?
    end

    # The `:name` placeholders of SQL text against `args:`: `?`, `$name` and `@name` are refused, every `:name`
    # must be declared, every declared argument must be used.
    def check_placeholders(node, what, name, sql, args)
      named = []
      Db::Sql.placeholders(sql).each do |ph|
        case ph.kind
        when :named then named << ph.name
        when :anonymous, :numbered
          bad(node, "#{what} `#{name}` uses a `?` placeholder; write `:name` and declare it in `args:` (SQLite binds `:name` natively, so the SQL stays as written)")
        else
          sigil = ph.kind == :dollar ? "$" : "@"
          bad(node, "#{what} `#{name}` uses `#{sigil}#{ph.name}`; write `:#{ph.name}` instead: `:name` is the placeholder syntax here")
        end
      end
      named.uniq!
      if (missing = (named - args.keys).first)
        declared = args.empty? ? "" : " (declared: #{args.keys.join(', ')})"
        bad(node, "#{what} `#{name}`: the SQL uses `:#{missing}` but `args:` does not declare it#{declared}", word: missing, from: args.keys)
      end
      return unless (extra = (args.keys - named).first)

      bad(node, "#{what} `#{name}`: `args:` declares `#{extra}` but the SQL has no `:#{extra}` placeholder")
    end

    # Once every table, model, scope and record is read (after check_models, before check_queries): each relation
    # statement is read into Db::Rel, rendered, matched with its record and given its SQL, in place, so the entries
    # keep the order they were declared in.
    def check_relation_queries(srv)
      return unless @relation_queries

      schema = Db::Schema.from_ir(srv["tables"])
      models = Db::Models.from_ir(srv["models"], srv["exprs"], schema)
      @relation_queries.each do |name, rq|
        entry = rq[:entry]
        args = entry["args"].to_h
        label = "#{entry['kind']} `#{name}`"
        chain = Db::Chain.new(model: rq[:model], models: models, schema: schema, args: args, label: label,
                              kind: entry["kind"], bad: method(:bad))
        out = chain.call(rq[:body], entry["returns"])
        resolve_relation_record(srv, rq, label, entry["returns"], out[:returns], out[:sources])
        (out[:sqls] || [out[:sql]]).each { |sql| check_placeholders(rq[:node], entry["kind"], name, sql, args) }
        entry["sql"] = out[:sql]
        next unless out[:sqls]

        entry["sqls"] = out[:sqls]
        announce_destroy(rq, label, out[:sqls])
      end
    end

    # --- has_one_attached (docs/database.md, "Attachments") ---------------------------------------------------------------

    ATTACHMENT_TABLE = "active_storage_attachments"
    BLOB_TABLE = "active_storage_blobs"
    ATTACHED_COLUMNS = { ATTACHMENT_TABLE => %w[name record_type record_id blob_id],
                         BLOB_TABLE => %w[key filename content_type metadata service_name byte_size checksum] }.freeze

    # The models that own Active Storage's tables, [attachment model, blob model]: a `has_one_attached` reads and writes
    # through them, whatever they are named.
    def attached_models(node, who)
      [ATTACHMENT_TABLE, BLOB_TABLE].map do |table|
        owners = @models.values.select { |m| m["table"] == table }.map { |m| m["name"] }
        bad(node, "#{who} needs a model that owns the table `#{table}`: `model :#{table == ATTACHMENT_TABLE ? 'Attachment' : 'Blob'}, table: :#{table}`") if owners.empty?
        bad(node, "#{who}: the table `#{table}` is owned by several models (#{owners.join(', ')}), so no one model reads it") if owners.size > 1
        owners.first
      end
    end

    # The derived `:<name>_attachment` association names the attachment model (check_models, before the registry is built).
    def resolve_attached(models)
      models.each_value do |m|
        (m["attached"] || []).each do |a|
          node = @attached_nodes.fetch([m["name"], a["name"]])
          attachment, = attached_models(node, "model \"#{m['name']}\" has_one_attached :#{a['name']}")
          m["associations"].find { |x| x["name"] == "#{a['name']}_attachment" }["model"] = attachment
        end
      end
    end

    # The statements `attach(:name, owner_id, stored)` runs, made as if written in the models that own their tables: the blob
    # row, the old attachment removed, the attachment row and the owner touched. They are ordinary relation statements, rendered
    # by check_relation_queries, each carrying where it came from ("derived"), and `attach` (body.rb) is the one call that runs
    # them, in this order. @flags["attached"] tells it their names.
    def check_attached(srv)
      @models&.each_value do |m|
        (m["attached"] || []).each { |a| add_attached_statements(srv, m, a) }
      end
    end

    def add_attached_statements(srv, model, attached)
      name = attached["name"]
      node = @attached_nodes.fetch([model["name"], name])
      who = "model \"#{model['name']}\" has_one_attached :#{name}"
      attachment_model, blob_model = attached_models(node, who)
      schema = Db::Schema.from_ir(srv["tables"])
      ATTACHED_COLUMNS.each do |table, columns|
        have = schema.columns(table).map { |c| c[:name] }
        missing = columns - have
        bad(node, "#{who}: table `#{table}` has no column `#{missing.first}` (columns: #{have.join(', ')})", word: missing.first, from: have) unless missing.empty?
      end
      other = (@flags["attached"] || {})[name]
      bad(node, "#{who}: model \"#{other['model']}\" declares `has_one_attached :#{name}` too, and `attach(:#{name}, ...)` names the attachment alone; give them different names") if other
      snake = model["name"].split("::").last.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
      stem = "#{snake}_#{name}"
      owner = "#{snake}_id"
      owner_args = { owner => "i64" }
      specs = [
        ["insert", "insert_#{stem}_blob", blob_model,
         { "key" => "string", "filename" => "string", "content_type" => "string", "metadata" => "string", "byte_size" => "i64", "checksum" => "string" },
         'insert(key: arg(:key), filename: arg(:filename), content_type: arg(:content_type), metadata: arg(:metadata), service_name: "local", byte_size: arg(:byte_size), checksum: arg(:checksum))'],
        ["detach", "detach_#{stem}", attachment_model, owner_args,
         "where(record_type: \"#{model['name']}\", record_id: arg(:#{owner}), name: \"#{name}\").delete"],
        ["attach", "attach_#{stem}", attachment_model, owner_args.merge("key" => "string"),
         "insert_from(#{blob_model}.where(key: arg(:key)), name: \"#{name}\", record_type: \"#{model['name']}\", record_id: arg(:#{owner}), blob_id: :id)"]
      ]
      if schema.columns(model["table"]).any? { |c| c[:name] == "updated_at" }
        specs << ["touch", "touch_#{stem}", model["name"], owner_args, "where(id: arg(:#{owner})).touch"]
      end
      derived = { "from" => attached["from"], "at" => attached["at"] }
      statements = {}
      specs.each do |role, sname, owner_model, args, source|
        bad(node, "#{who} makes the statement `#{sname}`, which is already declared; remove that one (`attach(:#{name}, ...)` runs the generated statement)") if @flags.dig("queries", sname)
        entry = { "name" => sname, "kind" => "execute", "args" => args.to_a, "sql" => nil,
                  "at" => "#{AxumDsl.file_of(node) || @path}:#{node.location.start_line}", **located(node),
                  "shape" => "execute", "rtype" => "i64", "derived" => derived }
        srv["queries"] << entry
        (@query_nodes ||= {})[sname] = node
        (@flags["queries"] ||= {})[sname] = entry
        (@relation_queries ||= {})[sname] = { node: node, model: owner_model, body: Prism.parse(source).value.statements, entry: entry,
                                              records_at: srv["records"].size }
        statements[role] = sname
        graph_attached_statement(model["name"], name, sname, role, derived)
      end
      (@flags["attached"] ||= {})[name] = { "model" => model["name"], "owner_arg" => owner, "statements" => statements, **derived }
    end

    # The notice lists the statements with their SQL in the order `attach` runs them, so none of it is hidden.
    def announce_attached(_srv)
      (@flags["attached"] || {}).each do |name, info|
        list = info["statements"].values.each_with_index.map { |sname, i| "#{i + 1}. #{sname}: #{@flags['queries'].fetch(sname)['sql']}" }.join("; ")
        Notify.add(@path, @attached_nodes.fetch([info["model"], name]), "N-ATTACHED",
                   "#{info['from']} of model \"#{info['model']}\" derives the associations `#{name}_attachment` and `#{name}_blob`, " \
                   "the condition `attached(:#{name})` and the statements `attach(:#{name}, #{info['owner_arg']}, stored)` runs in this order " \
                   "inside a `transaction` (`fresh: true` leaves out the detach and the touch): #{list}")
      end
    end
    # A destroy runs several statements as one unit (the call site must be a `transaction`); the notice lists them in
    # the order they run, so the deletes the `dependent:` declarations imply are not hidden.
    def announce_destroy(rq, label, sqls)
      list = sqls.each_with_index.map { |sql, i| "#{i + 1}. #{sql}" }.join("; ")
      Notify.add(@path, rq[:node], "N-DESTROY",
                 "#{label} destroys the row and what depends on it with #{sqls.size} statements, run in this order as one unit " \
                 "inside a `transaction`: #{list}")
    end

    # Where the record a relation query returns comes from. A declared record is matched as always
    # (match_relation_record). A name no `record` declares is DERIVED: the compiler declares it from the fields the
    # relation selects, in selection order, at the place of the first query that names it, as if the `record` block
    # were written there. Another relation query may name a derived record only when it selects the same fields in
    # the same order. A `sql:` query never derives: check_queries still refuses its unknown record, as it did. This
    # runs before check_queries and before any body is read, so a derived record is in srv["records"] for both.
    def resolve_relation_record(srv, rq, label, ret, got, sources = nil)
      return unless ret && %w[one list].include?(ret["shape"])

      name = ret["record"]
      first = (@derived_records ||= {})[name]
      if first
        check_same_derived(rq[:node], label, name, first, got[:fields])
      elsif srv["records"].any? { |r| r["name"] == name }
        match_relation_record(srv, rq[:node], label, ret, got)
      else
        derive_record(srv, rq, label, name, got[:fields])
      end
      graph_record_fields(srv, rq[:node], name, got[:fields], sources)
    end

    def derive_record(srv, rq, label, name, fields)
      list = fields.map { |f| { "name" => f[:name], "type" => f[:type].to_s, **(f[:optional] ? { "optional" => true } : {}) } }
      # Each earlier derived record sits before this spot, so it moves the index by one.
      srv["records"].insert(rq[:records_at] + @derived_records.size,
                            { "name" => name, "kind" => "record", "fields" => list, **located(rq[:node]) })
      @derived_records[name] = { label: label, fields: fields }
      (@record_nodes ||= {})[name] = rq[:node]
    end

    def check_same_derived(node, label, name, first, fields)
      key = ->(f) { [f[:name], f[:type].to_s, f[:optional] ? true : false] }
      shown = ->(f) { f ? "`#{f[:name]}` (:#{f[:type]}#{"?" if f[:optional]})" : "no field" }
      other = first[:fields]
      at = (0...[other.size, fields.size].max).find { |i| other[i].nil? || fields[i].nil? || key.call(other[i]) != key.call(fields[i]) }
      return unless at

      bad(node, "#{label} returns record `#{name}`, which #{first[:label]} derives from its own relation, but the two relations do not select " \
                "the same fields: field #{at + 1} is #{shown.call(other[at])} in #{first[:label]} and #{shown.call(fields[at])} here; " \
                "select the same fields in the same order, or declare `record :#{name}` and both are matched against it")
    end

    # A :time column is TEXT, held as a String, so a relation may fill a :time record field from a :string column and
    # the other way round. A :bool value (SQLite already holds it as 0 or 1) may fill an :i64 field, not the other way
    # round (an integer is not always 0 or 1); every other type must be the same.
    def same_column_type?(got, want) = got == want || [got, want].all? { |t| %w[string time].include?(t) } || (got == "bool" && want == "i64")

    # The record a relation query returns has the fields the relation selects: the same names, types and
    # optionality, in any order (the server matches columns to fields by name). Only a record that is declared
    # comes here (resolve_relation_record derives the others).
    def match_relation_record(srv, node, label, ret, got)
      return unless ret && %w[one list].include?(ret["shape"])

      rec = srv["records"].find { |r| r["name"] == ret["record"] } or return
      want = rec["fields"].reject { |f| f["from"] }
      have = got[:fields]
      show = ->(type, optional) { ":#{type}#{'?' if optional}" }
      have.each do |g|
        next if want.any? { |f| f["name"] == g[:name] }

        bad(node, "#{label}: the relation selects `#{g[:name]}` (#{show.call(g[:type], g[:optional])}), which record `#{rec['name']}` does not have " \
                  "(its fields: #{want.map { |f| f['name'] }.join(', ')})")
      end
      want.each do |f|
        g = have.find { |x| x[:name] == f["name"] }
        unless g
          bad(node, "#{label}: record `#{rec['name']}` has the field `#{f['name']}` (#{show.call(f['type'], f['optional'])}), which the relation does not select; add it to `select(...)`")
        end
        next if same_column_type?(g[:type].to_s, f["type"]) && g[:optional] == (f["optional"] ? true : false)

        bad(node, "#{label}: field `#{f['name']}` is #{show.call(f['type'], f['optional'])} in record `#{rec['name']}`, " \
                  "but the relation gives #{show.call(g[:type], g[:optional])}")
      end
    end
  end
end
