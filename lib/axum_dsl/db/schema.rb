# frozen_string_literal: true

module AxumDsl
  module Db
    # The schema registry: the tables a file declares with `table` (docs/database.md), each an ordered list of
    # columns `{ name:, type:, optional: }`. The reader keeps them in the IR under "tables"; the model layer reads
    # them through here. Nothing is emitted from a table.
    class Schema
      # The registry for an IR's "tables" entries.
      def self.from_ir(tables)
        schema = new
        tables.to_a.each { |t| schema.add(t["name"], t["columns"]) }
        schema
      end

      # table name => its columns, in declaration order.
      attr_reader :tables

      def initialize
        @tables = {}
      end

      def add(table, columns)
        @tables[table.to_s] = columns.map { |c| { name: c["name"].to_s, type: c["type"].to_s, optional: c["optional"] == true } }.freeze
      end

      def table?(table) = @tables.key?(table.to_s)

      # The columns of a table, or nil when it is not declared.
      def columns(table) = @tables[table.to_s]

      # One column, or nil when the table or the column is unknown.
      def column(table, col) = columns(table)&.find { |c| c[:name] == col.to_s }
    end
  end
end
