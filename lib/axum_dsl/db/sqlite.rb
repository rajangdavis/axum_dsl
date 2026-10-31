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
        ["rusqlite = { version = \"0.40\", features = [\"bundled\", \"hooks\", \"functions\"] }",
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
         *ir["queries"].to_a.each_with_index.map { |q, i|
           in_tx = ir["queries_in_tx"].to_a.include?(q["name"])
           outside = ir["queries_outside"].to_a.include?(q["name"])
           [q, "#{q['kind']} `#{q['name']}`", statement_lines(q, i, wrapper: !in_tx || outside, fills: list_fills(ir, q))]
         }]
      end

      def sql_const(q) = "DB_SQL_#{q['name'].upcase}"

      def field_rust(f)
        return "Vec<#{CompositeTypes.object_list_name(f['type'])}>" if f["from"]

        f["optional"] ? "Option<#{RUST.fetch(f['type'])}>" : RUST.fetch(f["type"])
      end

      # A record is a plain struct that is Serialize (json(...) writes it) and Clone (a body clones what it
      # reads), filled from a row by column name, so the order of the SELECT does not matter. A list field is no
      # column: from_row leaves it empty and the statement fills it, one sub-query per row (list_fills).
      def record_lines(r)
        name = r["name"]
        gets = r["fields"].map { |f| f["from"] ? "#{f['name']}: Vec::new()" : "#{f['name']}: __r.get(#{AxumDsl.rstr(f['name'])})?" }
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

      # The statements that fill a returned record's list fields, for the row variable `__row`: each runs the
      # field's sub-query on the same connection, its arguments the row's columns of the same names.
      def list_fills(ir, q)
        rec = ir["records"].to_a.find { |r| r["name"] == q["record"] } or return []
        rec["fields"].select { |f| f["from"] }.map do |f|
          sub = ir["queries"].find { |x| x["name"] == f["from"] }
          args = sub["args"].map { |n, t| t == "string" ? "__row.#{n}.clone()" : "__row.#{n}" }
          "__row.#{f['name']} = #{Db.on_name(sub)}(__c#{args.empty? ? '' : ", #{args.join(', ')}"})?;"
        end
      end

      def statement_lines(q, index, wrapper: true, fills: [])
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
            if fills.empty?
              ["let mut __stmt = __c.prepare_cached(#{sql_const(q)})?;",
               "let __rows = __stmt.query_map(#{binds}, #{rec}::from_row)?;",
               "let __out = __rows.collect::<rusqlite::Result<Vec<#{rec}>>>();",
               "__out"]
            else
              ["let mut __out = {",
               "    let mut __stmt = __c.prepare_cached(#{sql_const(q)})?;",
               "    let __rows = __stmt.query_map(#{binds}, #{rec}::from_row)?;",
               "    let __all = __rows.collect::<rusqlite::Result<Vec<#{rec}>>>();",
               "    __all",
               "}?;",
               "for __row in __out.iter_mut() {",
               *fills.map { |l| "    #{l}" },
               "}",
               "Ok(__out)"]
            end
          when "one"
            if fills.empty?
              ["let mut __stmt = __c.prepare_cached(#{sql_const(q)})?;",
               "let __out = rusqlite::OptionalExtension::optional(__stmt.query_row(#{binds}, #{rec}::from_row));",
               "__out"]
            else
              ["let mut __out = {",
               "    let mut __stmt = __c.prepare_cached(#{sql_const(q)})?;",
               "    let __one = rusqlite::OptionalExtension::optional(__stmt.query_row(#{binds}, #{rec}::from_row));",
               "    __one",
               "}?;",
               "if let Some(__row) = __out.as_mut() {",
               *fills.map { |l| "    #{l}" },
               "}",
               "Ok(__out)"]
            end
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
                    "    db_run(#{index}, #{AxumDsl.rstr(q['name'])}, move |__c| #{Db.on_name(q)}(__c#{args.empty? ? '' : ", #{args}"}))",
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
          "// Writers queue here, in the process, instead of in SQLite's busy handler (which sleeps 1 to 100 ms between",
          "// retries): once-campfire-rust/crates/db/src/database.rs runs every write on one thread for the same reason.",
          "// Taken before a pooled connection, so a waiting writer holds none. DB_WRITES says, per DB_STATEMENTS entry,",
          "// whether the statement writes (sqlite3_stmt_readonly, so a RETURNING write counts); reads never take it.",
          "static DB_WRITE_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());",
          "static DB_WRITES: std::sync::OnceLock<Vec<bool>> = std::sync::OnceLock::new();",
          "",
          "// Reads run on threads of their own, not tokio's blocking pool, as in once-campfire-rust/crates/db/src/database.rs: there a read",
          "// that found every connection busy parked a blocking thread, while here a waiting read costs a queue entry and a reader",
          "// that finishes takes the next read without a hand-off. One queue, DB_READERS threads, each with its own query_only connection.",
          "const DB_READERS: usize = 5;",
          "type DbRead = Box<dyn FnOnce(&mut rusqlite::Connection) + Send>;",
          "struct DbReadQueue {",
          "    jobs: std::sync::Mutex<std::collections::VecDeque<DbRead>>,",
          "    ready: std::sync::Condvar,",
          "}",
          "static DB_READS: std::sync::OnceLock<DbReadQueue> = std::sync::OnceLock::new();",
          "",
          "fn db_reader(mut __c: rusqlite::Connection) {",
          "    let queue = DB_READS.get().expect(\"the read queue is set before its readers start\");",
          "    loop {",
          "        let job = {",
          "            let mut jobs = queue.jobs.lock().unwrap_or_else(|p| p.into_inner());",
          "            loop {",
          "                if let Some(job) = jobs.pop_front() {",
          "                    break job;",
          "                }",
          "                jobs = queue.ready.wait(jobs).unwrap_or_else(|p| p.into_inner());",
          "            }",
          "        };",
          "        job(&mut __c);",
          "    }",
          "}",
          "",
          "// Runs the statement DB_STATEMENTS[index]: a read on a reader thread, a write on a pooled connection; an error names the query.",
          *(wrappers ? [] : ["#[allow(dead_code)]"]),
          "async fn db_run<T: Send + 'static>(",
          "    index: usize,",
          "    name: &'static str,",
          "    work: impl FnOnce(&mut rusqlite::Connection) -> rusqlite::Result<T> + Send + 'static,",
          ") -> Result<T, String> {",
          "    if let (true, Some(queue)) = (DB_WRITES.get().is_some_and(|w| !w[index]), DB_READS.get()) {",
          "        let (tx, rx) = tokio::sync::oneshot::channel();",
          "        let job: DbRead = Box::new(move |__c| {",
          "            let __out = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| work(__c)));",
          "            let _ = tx.send(__out);",
          "        });",
          "        queue.jobs.lock().unwrap_or_else(|p| p.into_inner()).push_back(job);",
          "        queue.ready.notify_one();",
          "        return match rx.await {",
          "            Ok(Ok(out)) => out.map_err(|e| format!(\"query `{name}`: {e}\")),",
          "            Ok(Err(_)) => Err(format!(\"query `{name}`: the read panicked\")),",
          "            Err(_) => Err(format!(\"query `{name}`: the database reader is gone\")),",
          "        };",
          "    }",
          "    let _write = if DB_WRITES.get().is_some_and(|w| w[index]) { Some(DB_WRITE_LOCK.lock().await) } else { None };",
          "    let conn = db().get().await.map_err(|e| format!(\"query `{name}`: no database connection: {e}\"))?;",
          "    conn.interact(move |__c| {",
          "        let __out = work(__c)?;",
          "        db_after_write(__c);",
          "        Ok::<T, rusqlite::Error>(__out)",
          "    })",
          "    .await",
          "    .map_err(|e| format!(\"query `{name}`: {e}\"))?",
          "    .map_err(|e| format!(\"query `{name}`: {e}\"))",
          "}",
          "",
          *(ir["transactions"] ? transaction_lines : []),
          "async fn db_open() -> Result<(), String> {",
          *path,
          "    let pool = deadpool_sqlite::Config::new(path.clone())",
          "        .builder(deadpool_sqlite::Runtime::Tokio1)",
          "        .map_err(|e| format!(\"database {path}: cannot create the connection pool: {e}\"))?",
          "        .post_create(deadpool_sqlite::Hook::async_fn(|conn, _| {",
          "            Box::pin(async move {",
          "                conn.interact(db_connection_setup)",
          "                    .await",
          "                    .map_err(|e| deadpool_sqlite::HookError::message(e.to_string()))?",
          "                    .map_err(deadpool_sqlite::HookError::message)",
          "            })",
          "        }))",
          "        .build()",
          "        .map_err(|e| format!(\"database {path}: cannot create the connection pool: {e}\"))?;",
          "    let conn = pool.get().await.map_err(|e| format!(\"database {path}: cannot open it: {e}\"))?;",
          "    conn.interact(db_startup)",
          "        .await",
          "        .map_err(|e| format!(\"database {path}: {e}\"))??;",
          "    let (__wake, __woken) = std::sync::mpsc::sync_channel::<()>(1);",
          "    let mut __checkpointer = rusqlite::Connection::open(&path).map_err(|e| format!(\"database {path}: cannot open the checkpointer connection: {e}\"))?;",
          "    db_connection_setup(&mut __checkpointer).map_err(|e| format!(\"database {path}: {e}\"))?;",
          "    std::thread::Builder::new()",
          "        .name(\"db-checkpointer\".into())",
          "        .spawn(move || {",
          "            while __woken.recv().is_ok() {",
          "                let _running = DB_CHECKPOINT_RUNNING.lock().unwrap_or_else(|p| p.into_inner());",
          "                db_checkpoint(&__checkpointer, \"PASSIVE\");",
          "            }",
          "        })",
          "        .map_err(|e| format!(\"database {path}: cannot start the checkpointer: {e}\"))?;",
          "    let _ = DB_WAKE.set(__wake);",
          "    let _ = DB_READS.set(DbReadQueue { jobs: Default::default(), ready: Default::default() });",
          "    for _ in 0..DB_READERS {",
          "        let mut __reader = rusqlite::Connection::open(&path).map_err(|e| format!(\"database {path}: cannot open a reader connection: {e}\"))?;",
          "        db_connection_setup(&mut __reader).map_err(|e| format!(\"database {path}: {e}\"))?;",
          "        __reader.pragma_update(None, \"query_only\", true).map_err(|e| format!(\"database {path}: cannot make a reader query_only: {e}\"))?;",
          "        std::thread::Builder::new()",
          "            .name(\"db-reader\".into())",
          "            .spawn(move || db_reader(__reader))",
          "            .map_err(|e| format!(\"database {path}: cannot start a reader: {e}\"))?;",
          "    }",
          "    let _ = DB.set(pool);",
          *(ResponseCache.used?(ir) ? [ResponseCache.open_line(ir)] : []),
          "    Ok(())",
          "}",
          "",
          *migration_lines(migrations),
          *statement_table(queries),
          "// Per-connection settings, run on every connection the pool opens (journal_mode=WAL is a property of",
          "// the database file and is set once in db_startup). The statement cache holds every declared statement,",
          "// at least rusqlite's default of 16, so prepare_cached never evicts one it will need again.",
          "fn db_connection_setup(__c: &mut rusqlite::Connection) -> Result<(), String> {",
          "    __c.execute_batch(\"PRAGMA synchronous=NORMAL; PRAGMA cache_size=2000; PRAGMA journal_size_limit=67108864;\")",
          "        .map_err(|e| format!(\"database: cannot set the connection pragmas: {e}\"))?;",
          "    __c.set_prepared_statement_cache_capacity(#{[16, queries.size].max});",
          "    __c.wal_hook(Some(db_note_wal_size));",
          *(Sanitize.attachable_ids_sql?(ir) ? [
            "    // SQL function `action_text_attachable_ids(html, 'User')`: a JSON array of the ids the sgids of a body's",
            "    // <action-text-attachment>s name (docs/database.md).",
            "    __c.create_scalar_function(\"action_text_attachable_ids\", 2, rusqlite::functions::FunctionFlags::SQLITE_UTF8 | rusqlite::functions::FunctionFlags::SQLITE_DETERMINISTIC, |ctx| {",
            "        let html: String = ctx.get(0)?;",
            "        let model: String = ctx.get(1)?;",
            "        Ok(axum_dsl_attachable_ids_json(&html, &model))",
            "    })",
            "    .map_err(|e| format!(\"database: cannot register action_text_attachable_ids: {e}\"))?;"
          ] : []),
          "    Ok(())",
          "}",
          "",
          *checkpoint_lines(ResponseCache.used?(ir)),
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
        ["// Runs `work` on one pooled connection inside a SQLite transaction, opened IMMEDIATE so a write never",
         "// starts as a reader that cannot upgrade (as Rails does, once-campfire-rust/crates/db/src/database.rs): it",
         "// commits when `work` returns Ok and rolls back when it returns Err (dropping the transaction). An error names the transaction.",
         "async fn db_tx<T: Send + 'static>(",
         "    name: &'static str,",
         "    work: impl FnOnce(&rusqlite::Connection) -> rusqlite::Result<T> + Send + 'static,",
         ") -> Result<T, String> {",
         "    let _write = DB_WRITE_LOCK.lock().await; // before the pooled connection, as in db_run",
         "    let conn = db().get().await.map_err(|e| format!(\"transaction `{name}`: no database connection: {e}\"))?;",
         "    conn.interact(move |__c| {",
         "        let mut __tx = __c.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;",
         "        let __out = work(&__tx)?;",
         "        __tx.commit()?;",
         "        db_after_write(__c);",
         "        Ok::<T, rusqlite::Error>(__out)",
         "    })",
         "    .await",
         "    .map_err(|e| format!(\"transaction `{name}`: {e}\"))?",
         "    .map_err(|e| format!(\"transaction `{name}`: {e}\"))",
         "}",
         ""]
      end

      # Checkpoints off the committing request, adapted from once-campfire-rust/crates/db/src/database.rs to a
      # pool: every connection's WAL hook (which replaces the per-commit auto-checkpoint) notes the WAL size, a
      # write that committed wakes a checkpointer thread per 1,000 pages, and at 10,000 runs RESTART itself.
      def checkpoint_lines(cache)
        ["// Checkpoints run off the committing request (once-campfire-rust/crates/db/src/database.rs, measured in",
         "// plans/perf-attribution.md): the WAL hook below replaces SQLite's auto-checkpoint and only notes the WAL size.",
         "const DB_AUTOCHECKPOINT_PAGES: i32 = 1000;",
         "const DB_WAL_LIMIT_PAGES: i32 = 10_000;",
         "static DB_WAL_PAGES: std::sync::atomic::AtomicI32 = std::sync::atomic::AtomicI32::new(0);",
         "static DB_WOKEN_AT: std::sync::atomic::AtomicI32 = std::sync::atomic::AtomicI32::new(0);",
         "static DB_WAKE: std::sync::OnceLock<std::sync::mpsc::SyncSender<()>> = std::sync::OnceLock::new();",
         "// Held while the checkpointer runs, so a RESTART waits for it rather than being refused.",
         "static DB_CHECKPOINT_RUNNING: std::sync::Mutex<()> = std::sync::Mutex::new(());",
         "",
         "// SQLite calls this only for a commit that wrote frames, so a write that changed nothing (an UPDATE whose",
         "// WHERE matched no row) does not move the response cache's generation.",
         "fn db_note_wal_size(_: &rusqlite::hooks::Wal, pages: std::os::raw::c_int) -> rusqlite::Result<()> {",
         *(cache ? ["    axum_dsl_cache_note_commit();"] : []),
         "    DB_WAL_PAGES.store(pages, std::sync::atomic::Ordering::Relaxed);",
         "    Ok(())",
         "}",
         "",
         "// After a write on `__c`: wake the checkpointer per 1,000 pages the WAL grew, RESTART it past 10,000.",
         "fn db_after_write(__c: &rusqlite::Connection) {",
         "    match DB_WAL_PAGES.swap(0, std::sync::atomic::Ordering::Relaxed) {",
         "        0 => {}",
         "        pages if pages >= DB_WAL_LIMIT_PAGES => {",
         "            let _running = DB_CHECKPOINT_RUNNING.lock().unwrap_or_else(|p| p.into_inner());",
         "            db_checkpoint(__c, \"RESTART\");",
         "        }",
         "        pages => {",
         "            let woken_at = DB_WOKEN_AT.load(std::sync::atomic::Ordering::Relaxed);",
         "            if pages < woken_at {",
         "                DB_WOKEN_AT.store(0, std::sync::atomic::Ordering::Relaxed); // the WAL restarted",
         "            }",
         "            let woken_at = DB_WOKEN_AT.load(std::sync::atomic::Ordering::Relaxed);",
         "            // While a checkpoint is still due (the channel is full), the next write tries again.",
         "            if pages - woken_at >= DB_AUTOCHECKPOINT_PAGES && DB_WAKE.get().is_some_and(|w| w.try_send(()).is_ok()) {",
         "                DB_WOKEN_AT.store(pages, std::sync::atomic::Ordering::Relaxed);",
         "            }",
         "        }",
         "    }",
         "}",
         "",
         "// A checkpoint that could not finish is reported in the `busy` column, not as an error.",
         "fn db_checkpoint(__c: &rusqlite::Connection, mode: &str) {",
         "    match __c.query_row(&format!(\"PRAGMA wal_checkpoint({mode})\"), [], |__r| __r.get::<_, i64>(0)) {",
         "        Ok(0) => {}",
         "        Ok(_) => eprintln!(\"database: WAL checkpoint {mode} could not finish\"),",
         "        Err(e) => eprintln!(\"database: WAL checkpoint {mode} failed: {e}\"),",
         "    }",
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
          "    let mut __writes = Vec::with_capacity(DB_STATEMENTS.len());",
          "    for &(__name, __at, __sql, __check, __fields) in DB_STATEMENTS {",
          "        let __stmt = __c.prepare(__sql).map_err(|e| format!(\"{__at}: query `{__name}`: {e}\"))?;",
          "        __writes.push(!__stmt.readonly());",
          "        match __check {",
          *arms,
          "            _ => {}",
          "        }",
          "    }",
          "    let _ = DB_WRITES.set(__writes);"
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
