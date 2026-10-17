# frozen_string_literal: true

require_relative "db/sql"
require_relative "db/sqlite"

module AxumDsl
  # SQL state: `database`, `record`, `query`, `execute` and `migrations` (docs/database.md). The SQL a service
  # carries is the user's own text and runs as written; this module holds what is common to every adapter,
  # and each adapter (db/sqlite.rb is the only one) is a module that knows its driver and its dialect.
  module Db
    # The scalar types a query takes as arguments and a record holds as fields: the columns SQLite stores.
    SCALARS = %w[string i64 f64 bool].freeze

    # database's first argument => the module that emits for it. Only :sqlite is built.
    ADAPTERS = { "sqlite" => Sqlite }.freeze

    module_function

    def backend(adapter) = ADAPTERS.fetch(adapter)

    # The Rust function a `query` or `execute` is called through. The body compiler names it and the backend
    # defines it, so the one spelling lives here.
    def fn_name(q) = "query_#{q['name']}"

    # The synchronous core of that statement, on a connection the caller already holds: the async wrapper
    # calls it on a pooled connection, and a `transaction` block calls it on the transaction's connection.
    def on_name(q) = "#{fn_name(q)}_on"
  end
end
