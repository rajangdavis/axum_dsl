# frozen_string_literal: true

module AxumDsl
  # Warnings (behaviour differs from what the source suggests) and notices
  # (informational). They never change generated code and never fail the build;
  # the environment only decides what is PRINTED. SPEC.md sections 9.3 and 9.4.
  #
  #   AXUM_DSL_WARN=all|none|CODE,CODE      (default all)
  #   AXUM_DSL_NOTICE=all|none|CODE,CODE    (default all)
  module Notify
    Note = Struct.new(:code, :level, :path, :line, :col, :message)

    CODES = { "N-STR-STRIP-RUBY" => :notice, "N-STR-STRIP-RUST" => :notice,
              "W-BINDING-UNLOADED" => :warning,
              "W-STR-CAPITALIZE" => :warning,
              "N-RUST-INJECTED" => :notice,
              "W-RUST-FN-MISSING" => :warning,
              "N-FILE-UNCHECKED" => :notice,
              "W-FILE-ARGS-UNCHECKED" => :warning,
              "N-EXEC-INJECTED" => :notice,
              "N-BINDING" => :notice,
              "N-OPENAPI" => :notice,
              "N-DEPRECATED-FEATURE" => :notice }.freeze
    GATES = { warning: "AXUM_DSL_WARN", notice: "AXUM_DSL_NOTICE" }.freeze

    @notes = []

    class << self
      attr_reader :notes

      def reset! = @notes = []

      # The notes the gates allow, for callers that print them their own way (check --format json).
      def visible(env = ENV)
        GATES.each_value { |var| validate(var, env) }
        @notes.select { |note| shown?(note, env) }
      end

      def add(path, node, code, message)
        loc = node.location
        @notes << Note.new(code, CODES.fetch(code), AxumDsl.file_of(node) || path, loc.start_line, loc.start_column + 1, message)
      end

      # Prints what the gates allow and counts the rest. Returns the hidden notes.
      # An unknown code in a gate is an error, so a typo cannot silently hide nothing.
      def report(io = $stderr, env = ENV)
        GATES.each_value { |var| validate(var, env) }
        hidden = []
        @notes.each do |note|
          if shown?(note, env)
            io.puts "#{note.path}:#{note.line}:#{note.col}: #{note.level} #{note.code}: #{note.message}"
          else
            hidden << note
          end
        end
        unless hidden.empty?
          tally = hidden.group_by(&:code).map { |code, ns| "#{code} x#{ns.size}" }.join(", ")
          io.puts "#{hidden.size} notification(s) hidden (#{tally})"
        end
        hidden
      end

      private

      def setting(var, env) = env.fetch(var, "all").strip

      def validate(var, env)
        value = setting(var, env)
        return if %w[all none].include?(value)

        unknown = value.split(",").map(&:strip) - CODES.keys
        raise CompileError, "#{var}: unknown code(s) #{unknown.join(', ')}" unless unknown.empty?
      end

      def shown?(note, env)
        value = setting(GATES.fetch(note.level), env)
        return true if value == "all"
        return false if value == "none"

        value.split(",").map(&:strip).include?(note.code)
      end
    end
  end
end
