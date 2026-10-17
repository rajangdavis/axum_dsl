# frozen_string_literal: true

module AxumDsl
  module Lsp
    # What the compiler says about one version of one document: the CompileError `check` would print, split into
    # one diagnostic per FILE:LINE:COL row and carrying its "did you mean" suggestions, or - when the file
    # compiles - the warnings and notices the environment's gates allow. Nothing is cached across versions: a
    # document is re-analysed per change, which is milliseconds.
    #
    # The text compiled is the editor's buffer, not the file on disk (Lsp::Sources, which the reader consults).
    class Analysis
      # message: the text without the "FILE:LINE:COL:" prefix. end_col is 1-based exclusive, on the same line.
      # severity is LSP's: 1 an error, 2 a warning, 3 a notice. code is the compiler's own, when it has one.
      Diagnostic = Struct.new(:line, :col, :end_col, :message, :suggestions, :severity, :code, keyword_init: true) do
        def initialize(**kw)
          super
          self.severity ||= 1
          self.suggestions ||= []
        end
      end

      ROW = /\A(.+?):(\d+):(\d+): (.*)\z/

      attr_reader :path, :text, :lines, :diagnostics

      def initialize(path, text)
        @path = path
        @real = AxumDsl.canon(path)
        @text = text.to_s
        @lines = @text.split("\n", -1)
        @diagnostics = []
        @ok = false
        compile
      end

      def ok? = @ok

      def line_text(line) = @lines[line - 1].to_s

      private

      def compile
        Sources.with(@path, @text) { AxumDsl.read(@path) }
        @ok = true
        @diagnostics = visible_notes
      rescue CompileError => e
        @diagnostics = sort_errors(e)
      rescue SystemCallError => e
        @diagnostics = syntax_diagnostics(e) # neither an open buffer nor a file on disk: the reader's ENOENT (see below)
      rescue StandardError => e
        @diagnostics = [internal(e)] # a compiler bug must not take the editor down
      end

      # The warnings and notices `check` would print for this file, as LSP information and warnings. A notice
      # names the file it belongs to (a use_dsl fragment, a binding), and only this document's are published
      # here: another file's own analysis is what speaks for it when it is open.
      def visible_notes
        Notify.visible.filter_map do |note|
          next unless AxumDsl.canon(note.path) == @real

          Diagnostic.new(line: note.line, col: note.col, end_col: token_end(note.line, note.col),
                         message: note.message, severity: note.level == :warning ? 2 : 3, code: note.code)
        end
      rescue CompileError
        [] # a malformed AXUM_DSL_WARN/AXUM_DSL_NOTICE gate: `check` refuses it, so the editor gets no notes
      end

      # CompileError#message is "FILE:LINE:COL: text", one per line; a row that does not start with that prefix
      # continues the previous message. Suggestions belong to the last (only) semantic error. A row from another
      # file - a use_dsl fragment, a binding - is anchored on the line that brings that file in, so a failure in
      # a file the editor is not showing is still reported.
      def sort_errors(error)
        rows = []
        error.message.to_s.split("\n").each do |row|
          if (m = ROW.match(row))
            rows << { file: m[1], line: m[2].to_i, col: m[3].to_i, message: m[4] }
          elsif rows.any?
            rows.last[:message] = "#{rows.last[:message]}\n#{row}"
          else
            rows << { file: @path, line: 1, col: 1, message: row }
          end
        end
        rows = [{ file: @path, line: 1, col: 1, message: error.message.to_s }] if rows.empty?
        last = rows.size - 1
        rows.each_with_index.map do |row, i|
          ours = AxumDsl.canon(row[:file]) == @real
          line = ours ? row[:line] : use_dsl_line(row[:file])
          message = ours ? row[:message] : "#{row[:file]}:#{row[:line]}:#{row[:col]}: #{row[:message]}"
          Diagnostic.new(line: line, col: ours ? row[:col] : 1,
                         end_col: ours ? token_end(line, row[:col]) : line_text(line).bytesize + 1,
                         message: message, suggestions: i == last ? Array(error.suggestions) : [])
        end
      end

      # The line of this document that pulls `file` in, or 1 when nothing names it (a fragment that comes in
      # through another fragment, which this file never names).
      def use_dsl_line(file)
        want = AxumDsl.canon(file)
        dir = File.dirname(File.expand_path(@path))
        found = @lines.index do |l|
          (m = l.match(/\A\s*use_dsl\s+"([^"]+)"/)) && AxumDsl.canon(File.expand_path(m[1], dir)) == want
        end
        found ? found + 1 : 1
      end

      # A document the reader could not open at all (neither an open buffer nor a file on disk): the reader's
      # Errno::ENOENT is not the buffer's, so parse the text the editor holds and report the syntax it has.
      def syntax_diagnostics(error)
        result = Prism.parse(@text)
        return [internal(error)] if result.errors.empty?

        result.errors.map do |e|
          line = e.location.start_line
          col = e.location.start_column + 1
          Diagnostic.new(line: line, col: col, end_col: token_end(line, col),
                         message: "#{@path}:#{line}:#{col}: syntax error: #{e.message}")
        end
      end

      def internal(error)
        Diagnostic.new(line: 1, col: 1, end_col: 2,
                       message: "axum_dsl internal error: #{error.class}: #{error.message}")
      end

      # The error position is the start of the offending node; underline its first token, or the rest of the
      # line when that is not a word. (The same underlining rmcp_dsl's analysis uses.)
      def token_end(line1, col)
        text = line_text(line1)
        rest = text.byteslice(col - 1, text.bytesize).to_s
        word = rest[/\A[A-Za-z0-9_?!:@$.]+/] || rest.rstrip
        col + [word.bytesize, 1].max
      end
    end
  end
end
