# frozen_string_literal: true

module AxumDsl
  # The typed Rails-console equivalent (docs/console.md). This file is the Rust half: the code the emitted binary
  # carries for `BINARY --console DB_PATH`. The Ruby half (the REPL, the line checker) is console.rb. Both are kept
  # free of the rest of the compiler so they can move into the later framework extraction.
  module Console
    module_function

    # The first statements of main when the binary is started with `--console`: the console loop, then exit, before
    # the settings are read or anything is bound. Emitted with every database, next to `--schema-check`.
    def main_lines
      ["    if std::env::args().nth(1).as_deref() == Some(\"--console\") {",
       "        std::process::exit(db_console(std::env::args().nth(2)));",
       "    }"]
    end

    # The Rust items of the console (SQLite, rusqlite and the crate's own serde_json), appended to the database
    # runtime. One JSON request per stdin line, `{"stmt": NAME, "args": {...}}`, one JSON response per stdout line:
    # `{"columns": [...], "rows": [[...]], "ms": N}` or `{"error": "..."}`. The first line is `{"ready": true, ...}`.
    # A statement runs as its prepared SQL with named binds; one that is not `readonly()` is refused, and the
    # connection is `query_only` besides. A database with migrations still to apply is refused at open.
    def rust_lines(ir)
      migrations = ir["migrations"]
      queries = ir["queries"].to_a
      pending =
        if migrations
          ["    let applied = db_console_applied(&c);",
           "    let mut pending: Vec<String> = Vec::new();",
           "    for &(file, sha, _) in DB_MIGRATIONS {",
           "        match applied.get(file) {",
           "            None => pending.push(file.to_string()),",
           "            Some(got) if got.as_str() != sha => pending.push(format!(\"{file} (changed after it was applied)\")),",
           "            Some(_) => {}",
           "        }",
           "    }",
           "    if !pending.is_empty() {",
           "        eprintln!(\"console: {path} has migrations that are not applied: {}; start the server once to apply them\", pending.join(\", \"));",
           "        return 2;",
           "    }"]
        else
          []
        end
      applied =
        if migrations
          ["",
           "fn db_console_applied(c: &rusqlite::Connection) -> std::collections::HashMap<String, String> {",
           "    let read = || -> rusqlite::Result<std::collections::HashMap<String, String>> {",
           "        let mut stmt = c.prepare(\"SELECT version, sha256 FROM axum_dsl_migrations\")?;",
           "        let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?;",
           "        rows.collect()",
           "    };",
           "    read().unwrap_or_default()", # no table yet: nothing is applied
           "}"]
        else
          []
        end
      table = queries.empty? ? "&[]" : "DB_STATEMENTS"
      [
        "// `--console DB_PATH` (docs/console.md): a read-only line protocol over the declared statements, for axum_dsl console.",
        "fn db_console_table() -> &'static [(&'static str, &'static str, &'static str, u8, &'static [&'static str])] {",
        "    #{table}",
        "}",
        *applied,
        "",
        "fn db_console(path: Option<String>) -> i32 {",
        "    use std::io::{BufRead, Write};",
        "    let Some(path) = path else {",
        "        eprintln!(\"usage: --console DB_PATH\");",
        "        return 2;",
        "    };",
        "    if !std::path::Path::new(&path).is_file() {",
        "        eprintln!(\"console: no database file at {path}\");",
        "        return 2;",
        "    }",
        "    let mut c = match rusqlite::Connection::open(&path) {",
        "        Ok(c) => c,",
        "        Err(e) => {",
        "            eprintln!(\"console: cannot open {path}: {e}\");",
        "            return 2;",
        "        }",
        "    };",
        "    if let Err(message) = db_connection_setup(&mut c) {",
        "        eprintln!(\"{message}\");",
        "        return 2;",
        "    }",
        "    if let Err(e) = c.pragma_update(None, \"query_only\", true) {",
        "        eprintln!(\"console: cannot make the connection query_only: {e}\");",
        "        return 2;",
        "    }",
        *pending,
        "    let mut out = std::io::stdout().lock();",
        "    let _ = writeln!(out, \"{}\", ::serde_json::json!({ \"ready\": true, \"statements\": db_console_table().len() }));",
        "    let _ = out.flush();",
        "    for line in std::io::stdin().lock().lines() {",
        "        let Ok(line) = line else { break };",
        "        if line.trim().is_empty() {",
        "            continue;",
        "        }",
        "        let reply = db_console_line(&c, &line).unwrap_or_else(|e| ::serde_json::json!({ \"error\": e }));",
        "        if writeln!(out, \"{reply}\").and_then(|_| out.flush()).is_err() {",
        "            break;",
        "        }",
        "    }",
        "    0",
        "}",
        "",
        "// One request line: the statement DB_STATEMENTS names, its named parameters bound from `args`, every row as JSON.",
        "fn db_console_line(c: &rusqlite::Connection, line: &str) -> Result<::serde_json::Value, String> {",
        "    let req: ::serde_json::Value = ::serde_json::from_str(line).map_err(|e| format!(\"the request is not JSON: {e}\"))?;",
        "    let name = req.get(\"stmt\").and_then(|v| v.as_str()).ok_or_else(|| \"the request needs a \\\"stmt\\\" name\".to_string())?;",
        "    let none = ::serde_json::Map::new();",
        "    let args = match req.get(\"args\") {",
        "        None | Some(::serde_json::Value::Null) => &none,",
        "        Some(::serde_json::Value::Object(m)) => m,",
        "        Some(_) => return Err(\"\\\"args\\\" must be an object\".to_string()),",
        "    };",
        "    let found: Vec<_> = db_console_table().iter().filter(|s| s.0 == name).collect();",
        "    if found.is_empty() {",
        "        return Err(format!(\"no statement `{name}`\"));",
        "    }",
        "    for s in &found {",
        "        let probe = c.prepare(s.2).map_err(|e| format!(\"statement `{name}`: {e}\"))?;",
        "        if !probe.readonly() {",
        "            return Err(format!(\"statement `{name}` writes, and the console is read-only\"));",
        "        }",
        "    }",
        "    let started = std::time::Instant::now();",
        "    let mut stmt = c.prepare(found[0].2).map_err(|e| format!(\"statement `{name}`: {e}\"))?;",
        "    let mut names: Vec<String> = Vec::new();",
        "    for i in 1..=stmt.parameter_count() {",
        "        let pname = stmt",
        "            .parameter_name(i)",
        "            .map(|p| p.trim_start_matches([':', '@', '$']).to_string())",
        "            .ok_or_else(|| format!(\"statement `{name}` has a positional parameter\"))?;",
        "        let value = args.get(&pname).ok_or_else(|| format!(\"statement `{name}` needs the argument `{pname}`\"))?;",
        "        let bound = match value {",
        "            ::serde_json::Value::Null => rusqlite::types::Value::Null,",
        "            ::serde_json::Value::Bool(b) => rusqlite::types::Value::Integer(i64::from(*b)),",
        "            ::serde_json::Value::Number(n) => match (n.as_i64(), n.as_f64()) {",
        "                (Some(i), _) => rusqlite::types::Value::Integer(i),",
        "                (None, Some(f)) => rusqlite::types::Value::Real(f),",
        "                _ => return Err(format!(\"argument `{pname}` is not a number SQLite can bind\")),",
        "            },",
        "            ::serde_json::Value::String(s) => rusqlite::types::Value::Text(s.clone()),",
        "            _ => return Err(format!(\"argument `{pname}` must be a number, a string, a bool or null\")),",
        "        };",
        "        stmt.raw_bind_parameter(i, bound).map_err(|e| format!(\"argument `{pname}`: {e}\"))?;",
        "        names.push(pname);",
        "    }",
        "    if let Some(extra) = args.keys().find(|k| !names.contains(k)) {",
        "        return Err(format!(\"statement `{name}` takes no argument `{extra}`\"));",
        "    }",
        "    let columns: Vec<String> = stmt.column_names().into_iter().map(|n| n.to_string()).collect();",
        "    let mut rows = stmt.raw_query();",
        "    let mut out: Vec<::serde_json::Value> = Vec::new();",
        "    while let Some(row) = rows.next().map_err(|e| format!(\"statement `{name}`: {e}\"))? {",
        "        let mut cells = Vec::with_capacity(columns.len());",
        "        for i in 0..columns.len() {",
        "            let cell = match row.get_ref(i).map_err(|e| format!(\"statement `{name}`: {e}\"))? {",
        "                rusqlite::types::ValueRef::Null => ::serde_json::Value::Null,",
        "                rusqlite::types::ValueRef::Integer(n) => ::serde_json::Value::from(n),",
        "                rusqlite::types::ValueRef::Real(f) => ::serde_json::Number::from_f64(f).map_or(::serde_json::Value::Null, ::serde_json::Value::Number),",
        "                rusqlite::types::ValueRef::Text(t) => ::serde_json::Value::String(String::from_utf8_lossy(t).into_owned()),",
        "                rusqlite::types::ValueRef::Blob(b) => ::serde_json::Value::String(format!(\"<blob, {} bytes>\", b.len())),",
        "            };",
        "            cells.push(cell);",
        "        }",
        "        out.push(::serde_json::Value::Array(cells));",
        "    }",
        "    let ms = (started.elapsed().as_secs_f64() * 100_000.0).round() / 100.0;",
        "    Ok(::serde_json::json!({ \"columns\": columns, \"rows\": out, \"ms\": ms }))",
        "}"
      ]
    end
  end
end
