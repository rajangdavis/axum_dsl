# frozen_string_literal: true

module AxumDsl
  module Db
    # The SQLite backend: everything that is specific to the database lives here, and the emitter reaches it
    # through four narrow calls (`deps`, `items`, `start_lines` and, from Db, `fn_name`), so a later adapter
    # is another module with the same four. The pool is deadpool-sqlite over rusqlite; a statement runs on a
    # pooled connection through `interact`, and the user's SQL is a constant in the crate, byte for byte,
    # bound with rusqlite's named parameters.
    module Sqlite
      RUST = { "i64" => "i64", "string" => "String", "f64" => "f64", "bool" => "bool" }.freeze

      # How startup checks a prepared statement (the number in DB_STATEMENTS): 0 only that the SQL prepares,
      # 1 that it returns at least one column, 2 that its column names are the record's field names.
      CHECK = { "execute" => 0, "scalar" => 1, "one" => 2, "list" => 2 }.freeze

      module_function

      # The Cargo.toml dependency lines this backend needs.
      def deps
        ["rusqlite = { version = \"0.40\", features = [\"bundled\"] }",
         "deadpool-sqlite = { version = \"0.14\", features = [\"bundled\"] }"]
      end

      # The statements at the top of main that open the database before anything is served. A database that
      # cannot be opened, migrated or checked stops the server with a message and exit status 2, like a
      # setting that cannot load.
      def start_lines
        ["    if let Err(message) = db_open().await {",
         "        eprintln!(\"{message}\");",
         "        std::process::exit(2);",
         "    }"]
      end

      # The Rust items of a service with a database, as [declaration, what, lines] triples: the declaration
      # carries the DSL line the emitter maps the lines back to (nil for the shared runtime).
      def items(ir)
        [*ir["records"].to_a.map { |r| [r, "record `#{r['name']}`", record_lines(r)] },
         [nil, nil, runtime_lines(ir)],
         *ir["queries"].to_a.map { |q|
           in_tx = ir["queries_in_tx"].to_a.include?(q["name"])
           outside = ir["queries_outside"].to_a.include?(q["name"])
           [q, "#{q['kind']} `#{q['name']}`", statement_lines(q, wrapper: !in_tx || outside)]
         }]
      end

      def sql_const(q) = "DB_SQL_#{q['name'].upcase}"

      def field_rust(f) = f["optional"] ? "Option<#{RUST.fetch(f['type'])}>" : RUST.fetch(f["type"])

      # A record is a plain struct that is Serialize (json(...) writes it) and Clone (a body clones what it
      # reads), filled from a row by column name, so the order of the SELECT does not matter.
      def record_lines(r)
        name = r["name"]
        gets = r["fields"].map { |f| "#{f['name']}: __r.get(#{AxumDsl.rstr(f['name'])})?" }
        ["#[derive(Clone, serde::Serialize)]",
         "struct #{name} {",
         *r["fields"].map { |f| "    #{f['name']}: #{field_rust(f)}," },
         "}",
         "",
         "impl #{name} {",
         "    fn from_row(__r: &rusqlite::Row<'_>) -> rusqlite::Result<#{name}> {",
         "        Ok(#{name} { #{gets.join(', ')} })",
         "    }",
         "}"]
      end

      # The Rust return type of a statement.
      def return_rust(q)
        case q["shape"]
        when "list" then "Vec<#{q['record']}>"
        when "one" then "Option<#{q['record']}>"
        when "scalar" then q["nilable"] ? "Option<#{RUST.fetch(q['type'])}>" : RUST.fetch(q["type"])
        else "i64"
        end
      end

      def statement_lines(q, wrapper: true)
        params = q["args"].map { |n, t| "#{n}: #{RUST.fetch(t)}" }.join(", ")
        binds =
          if q["args"].empty? then "rusqlite::params![]"
          else "rusqlite::named_params! { #{q['args'].map { |n, _| "#{AxumDsl.rstr(":#{n}")}: #{n}" }.join(', ')} }"
          end
        rec = q["record"]
        scalar = q["type"] && RUST[q["type"]]
        body =
          case q["shape"]
          when "list"
            ["let mut __stmt = __c.prepare_cached(#{sql_const(q)})?;",
             "let __rows = __stmt.query_map(#{binds}, #{rec}::from_row)?;",
             "let __out = __rows.collect::<rusqlite::Result<Vec<#{rec}>>>();",
             "__out"]
          when "one"
            ["let mut __stmt = __c.prepare_cached(#{sql_const(q)})?;",
             "let __out = rusqlite::OptionalExtension::optional(__stmt.query_row(#{binds}, #{rec}::from_row));",
             "__out"]
          when "scalar"
            if q["nilable"]
              ["let mut __stmt = __c.prepare_cached(#{sql_const(q)})?;",
               "let __out = rusqlite::OptionalExtension::optional(__stmt.query_row(#{binds}, |__r| __r.get::<_, Option<#{scalar}>>(0))).map(|__v| __v.flatten());",
               "__out"]
            else
              ["let mut __stmt = __c.prepare_cached(#{sql_const(q)})?;",
               "let __out = __stmt.query_row(#{binds}, |__r| __r.get::<_, #{scalar}>(0));",
               "__out"]
            end
          else
            ["let mut __stmt = __c.prepare_cached(#{sql_const(q)})?;",
             "let __out = __stmt.execute(#{binds}).map(|__n| __n as i64);",
             "__out"]
          end
        args = q["args"].map(&:first).join(", ")
        lines = ["const #{sql_const(q)}: &str = #{AxumDsl.rstr(q['sql'])};",
                 "",
                 "fn #{Db.on_name(q)}(__c: &rusqlite::Connection#{params.empty? ? '' : ", #{params}"}) -> rusqlite::Result<#{return_rust(q)}> {",
                 *body.map { |l| "    #{l}" },
                 "}"]
        if wrapper
          lines += ["",
                    "async fn #{Db.fn_name(q)}(#{params}) -> Result<#{return_rust(q)}, String> {",
                    "    db_run(#{AxumDsl.rstr(q['name'])}, move |__c| #{Db.on_name(q)}(__c#{args.empty? ? '' : ", #{args}"}))",
                    "    .await",
                    "}"]
        end
        lines
      end

      # The pool, how a statement reaches a connection, and what happens at startup: open the pool, then on one
      # connection set journal_mode=WAL, apply the migrations, and prepare every declared statement.
      def runtime_lines(ir)
        db = ir["database"]
        queries = ir["queries"].to_a
        # With every statement called inside a transaction, no pooled wrapper is emitted and db_run itself
        # would be dead; keep the -D warnings gate while allowing only that shared helper.
        wrappers = queries.any? do |q|
          !ir["queries_in_tx"].to_a.include?(q["name"]) || ir["queries_outside"].to_a.include?(q["name"])
        end
        migrations = ir["migrations"]
        path =
          if db["env"]
            ["    let path = match std::env::var(#{AxumDsl.rstr(db['env'])}) {",
             "        Ok(value) if !value.is_empty() => value,",
             "        _ => #{AxumDsl.rstr(db['path'])}.to_string(),",
             "    };"]
          else
            ["    let path = #{AxumDsl.rstr(db['path'])}.to_string();"]
          end
        [
          "// the database (database :#{db['adapter']}): the pool, the startup checks and the statements below are written by the compiler",
          "static DB: std::sync::OnceLock<deadpool_sqlite::Pool> = std::sync::OnceLock::new();",
          "",
          "fn db() -> &'static deadpool_sqlite::Pool {",
          "    DB.get().expect(\"the database is opened before the server starts\")",
          "}",
          "",
          "// Runs one statement on a pooled connection; an error names the query.",
          *(wrappers ? [] : ["#[allow(dead_code)]"]),
          "async fn db_run<T: Send + 'static>(",
          "    name: &'static str,",
          "    work: impl FnOnce(&mut rusqlite::Connection) -> rusqlite::Result<T> + Send + 'static,",
          ") -> Result<T, String> {",
          "    let conn = db().get().await.map_err(|e| format!(\"query `{name}`: no database connection: {e}\"))?;",
          "    conn.interact(work)",
          "        .await",
          "        .map_err(|e| format!(\"query `{name}`: {e}\"))?",
          "        .map_err(|e| format!(\"query `{name}`: {e}\"))",
          "}",
          "",
          *(ir["transactions"] ? transaction_lines : []),
          "async fn db_open() -> Result<(), String> {",
          *path,
          "    let pool = deadpool_sqlite::Config::new(path.clone())",
          "        .create_pool(deadpool_sqlite::Runtime::Tokio1)",
          "        .map_err(|e| format!(\"database {path}: cannot create the connection pool: {e}\"))?;",
          "    let conn = pool.get().await.map_err(|e| format!(\"database {path}: cannot open it: {e}\"))?;",
          "    conn.interact(db_startup)",
          "        .await",
          "        .map_err(|e| format!(\"database {path}: {e}\"))??;",
          "    let _ = DB.set(pool);",
          "    Ok(())",
          "}",
          "",
          *migration_lines(migrations),
          *statement_table(queries),
          "fn db_startup(__c: &mut rusqlite::Connection) -> Result<(), String> {",
          "    __c.execute_batch(\"PRAGMA journal_mode=WAL;\")",
          "        .map_err(|e| format!(\"database: cannot set journal_mode=WAL: {e}\"))?;",
          *(migrations ? migrate_loop : []),
          *(queries.empty? ? [] : check_loop(queries)),
          "    Ok(())",
          "}",
          *(queries.any? { |q| CHECK.fetch(q["shape"]) == 2 } ? ["", *columns_fn] : [])
        ]
      end

      # The transaction helper, written only into a crate whose bodies open `transaction do ... end`: an
      # unused private fn would be dead code, and the generated crate builds with warnings denied.
      def transaction_lines
        ["// Runs `work` on one pooled connection inside a SQLite transaction: it commits when `work` returns",
         "// Ok and rolls back when it returns Err (dropping the transaction). An error names the transaction.",
         "async fn db_tx<T: Send + 'static>(",
         "    name: &'static str,",
         "    work: impl FnOnce(&rusqlite::Connection) -> rusqlite::Result<T> + Send + 'static,",
         ") -> Result<T, String> {",
         "    let conn = db().get().await.map_err(|e| format!(\"transaction `{name}`: no database connection: {e}\"))?;",
         "    conn.interact(move |__c| {",
         "        let mut __tx = __c.transaction()?;",
         "        let __out = work(&__tx)?;",
         "        __tx.commit()?;",
         "        Ok::<T, rusqlite::Error>(__out)",
         "    })",
         "    .await",
         "    .map_err(|e| format!(\"transaction `{name}`: {e}\"))?",
         "    .map_err(|e| format!(\"transaction `{name}`: {e}\"))",
         "}",
         ""]
      end

      # The migrations, embedded: (file name, sha256 of its text, the text). Only axum_dsl_migrations is
      # created or written; any other table is left as it is.
      def migration_lines(migrations)
        return [] unless migrations

        rows = migrations["files"].map do |m|
          "    (#{AxumDsl.rstr(m['file'])}, #{AxumDsl.rstr(m['sha256'])}, #{AxumDsl.rstr(m['sql'])}),"
        end
        ["const DB_MIGRATIONS: &[(&str, &str, &str)] = &[", *rows, "];", ""]
      end

      def migrate_loop
        [
          "    __c.execute_batch(\"CREATE TABLE IF NOT EXISTS axum_dsl_migrations (version TEXT PRIMARY KEY, sha256 TEXT NOT NULL, applied_at TEXT NOT NULL);\")",
          "        .map_err(|e| format!(\"database: cannot create axum_dsl_migrations: {e}\"))?;",
          "    for &(__file, __sha, __sql) in DB_MIGRATIONS {",
          "        let __done: Option<String> = rusqlite::OptionalExtension::optional(",
          "            __c.query_row(\"SELECT sha256 FROM axum_dsl_migrations WHERE version = ?1\", rusqlite::params![__file], |__r| __r.get(0)),",
          "        )",
          "        .map_err(|e| format!(\"migration {__file}: {e}\"))?;",
          "        match __done {",
          "            Some(__applied) if __applied == __sha => continue,",
          "            Some(__applied) => {",
          "                return Err(format!(",
          "                    \"migration {__file} was changed after it was applied: the database recorded sha256 {__applied}, the file now has {__sha}; add a new migration instead of editing an applied one\"",
          "                ));",
          "            }",
          "            None => {}",
          "        }",
          "        let __tx = __c.transaction().map_err(|e| format!(\"migration {__file}: {e}\"))?;",
          "        __tx.execute_batch(__sql).map_err(|e| format!(\"migration {__file}: {e}\"))?;",
          "        __tx.execute(",
          "            \"INSERT INTO axum_dsl_migrations (version, sha256, applied_at) VALUES (?1, ?2, datetime('now'))\",",
          "            rusqlite::params![__file, __sha],",
          "        )",
          "        .map_err(|e| format!(\"migration {__file}: {e}\"))?;",
          "        __tx.commit().map_err(|e| format!(\"migration {__file}: {e}\"))?;",
          "    }"
        ]
      end

      # Every declared statement as (query name, DSL file:line, SQL, check, the record's field names).
      def statement_table(queries)
        return [] if queries.empty?

        rows = queries.map do |q|
          fields = (q["fields"] || []).map { |f| AxumDsl.rstr(f) }.join(", ")
          "    (#{AxumDsl.rstr(q['name'])}, #{AxumDsl.rstr(q['at'])}, #{sql_const(q)}, #{CHECK.fetch(q['shape'])}, &[#{fields}]),"
        end
        ["const DB_STATEMENTS: &[(&str, &str, &str, u8, &[&str])] = &[", *rows, "];", ""]
      end

      def check_loop(queries)
        arms = []
        arms << "            1 if __stmt.column_count() == 0 => {\n" \
                "                return Err(format!(\"{__at}: query `{__name}` returns no columns, but it is declared to return a single value\"));\n" \
                "            }" if queries.any? { |q| CHECK.fetch(q["shape"]) == 1 }
        arms << "            2 => {\n" \
                "                let __got: Vec<String> = __stmt.column_names().into_iter().map(|__n| __n.to_string()).collect();\n" \
                "                db_columns(__at, __name, &__got, __fields)?;\n" \
                "            }" if queries.any? { |q| CHECK.fetch(q["shape"]) == 2 }
        [
          "    for &(__name, __at, __sql, __check, __fields) in DB_STATEMENTS {",
          "        let __stmt = __c.prepare(__sql).map_err(|e| format!(\"{__at}: query `{__name}`: {e}\"))?;",
          "        match __check {",
          *arms,
          "            _ => {}",
          "        }",
          "    }"
        ]
      end

      # A query that returns a record must select exactly the record's fields, by name.
      def columns_fn
        [
          "fn db_columns(at: &str, name: &str, got: &[String], fields: &[&str]) -> Result<(), String> {",
          "    let missing: Vec<&str> = fields.iter().copied().filter(|f| !got.iter().any(|g| g == f)).collect();",
          "    let extra: Vec<&str> = got.iter().map(|g| g.as_str()).filter(|g| !fields.contains(g)).collect();",
          "    if missing.is_empty() && extra.is_empty() {",
          "        return Ok(());",
          "    }",
          "    Err(format!(",
          "        \"{at}: query `{name}` does not select the columns of its record: missing {missing:?}, not a field {extra:?}\"",
          "    ))",
          "}"
        ]
      end
    end
  end
end
