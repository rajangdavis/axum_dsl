# frozen_string_literal: true

require "json"

module AxumDsl
  module Lsp
    # Language Server Protocol over stdio: Content-Length framed JSON-RPC 2.0, UTF-8. This is what the `lsp`
    # subcommand starts. It answers `initialize`, tracks `didOpen`/`didChange`/`didSave`/`didClose`, compiles
    # the document it holds - the editor's buffer, not the file on disk (Lsp::Sources) - and publishes what the
    # compiler said as diagnostics. Hover and completion read that same analysis and answer from SIG, the table
    # the reader validates against.
    #
    # Set AXUM_DSL_LSP_LOG=FILE to append everything received and sent to FILE, with start and stop lines and
    # any crash, so a client that cannot talk to the server can be debugged. Nothing is ever written to stdout
    # except protocol messages.
    class Server
      PARSE_ERROR = -32_700
      METHOD_NOT_FOUND = -32_601
      INTERNAL_ERROR = -32_603

      Document = Struct.new(:text, :version, :analysis)

      # A client sends these whatever the capabilities say; an empty answer is better than a
      # method-not-found error.
      EMPTY_ANSWERS_RESULT = {
        "textDocument/documentLink" => [], "textDocument/documentHighlight" => [],
        "textDocument/foldingRange" => [], "textDocument/codeLens" => [], "textDocument/references" => [],
        "textDocument/declaration" => nil, "textDocument/typeDefinition" => nil,
        "textDocument/implementation" => nil, "textDocument/signatureHelp" => nil, "textDocument/formatting" => nil,
        "textDocument/rangeFormatting" => nil, "textDocument/onTypeFormatting" => nil, "textDocument/rename" => nil,
        "textDocument/prepareRename" => nil, "workspace/symbol" => []
      }.freeze

      def initialize(input, output)
        @input = input
        @output = output
        @documents = {}
        @shutdown = false
        @exit = false
        @input.binmode if @input.respond_to?(:binmode)
        @output.binmode if @output.respond_to?(:binmode)
      end

      # Reads messages until `exit` or end of input.
      def run
        log("==", "start pid=#{Process.pid} ruby=#{RUBY_VERSION} cwd=#{Dir.pwd} version=#{AxumDsl::VERSION}")
        until @exit
          raw = read_frame
          break if raw.nil?

          log("<-", raw)
          begin
            message = JSON.parse(raw)
          rescue JSON::ParserError => e
            report("bad JSON: #{e.message}")
            send_message(jsonrpc: "2.0", id: nil, error: { code: PARSE_ERROR, message: "parse error" })
            next
          end
          handle(message)
        end
        log("==", @exit ? "stop: exit received" : "stop: input closed")
        exit(0) if @shutdown
      rescue Exception => e # rubocop:disable Lint/RescueException -- logged, then re-raised
        log("!!", "crash #{e.class}: #{e.message}\n#{e.backtrace.to_a.first(15).join("\n")}")
        raise
      end

      # One decoded message. Requests are answered, notifications acted on; anything sent goes to the output.
      def handle(message)
        return unless message.is_a?(Hash)

        method = message["method"]
        return if method.nil? # a response to us; we send no requests

        params = message["params"] || {}
        if message.key?("id")
          respond(message["id"], method, params)
        else
          notify(method, params)
        end
      rescue StandardError => e
        report("#{method}: #{e.class}: #{e.message}")
        send_message(jsonrpc: "2.0", id: message["id"], error: { code: INTERNAL_ERROR, message: e.message }) if message.key?("id")
      end

      def uri_to_path(uri)
        rest = uri.sub(%r{\Afile://[^/]*}, "")
        rest.gsub(/(?:%\h\h)+/) { |m| [m.delete("%")].pack("H*").force_encoding(Encoding::UTF_8) }
      end

      private

      def read_frame
        length = nil
        loop do
          line = @input.gets("\n")
          return nil if line.nil?

          line = line.chomp
          break if line.empty? && length
          next if line.empty?

          length = Regexp.last_match(1).to_i if line =~ /\AContent-Length:\s*(\d+)/i
        end
        body = @input.read(length)
        body&.force_encoding(Encoding::UTF_8)
      end

      def send_message(hash)
        body = JSON.generate(hash)
        log("->", body)
        @output.write("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
        @output.flush
      end

      # A problem the server survives: to stderr (never stdout, which is the protocol) and to the log.
      def report(text)
        warn "axum_dsl lsp: #{text}"
        log("!!", text)
      end

      def log(direction, text)
        path = ENV["AXUM_DSL_LSP_LOG"]
        return if path.nil? || path.empty?

        File.open(path, "a") { |f| f.puts("#{Time.now.strftime('%H:%M:%S.%L')} #{direction} #{text}") }
      rescue SystemCallError
        nil
      end

      def respond(id, method, params)
        result =
          case method
          when "initialize" then initialize_result
          when "shutdown" then (@shutdown = true) && nil
          when "textDocument/hover" then hover(params)
          when "textDocument/completion" then completion(params)
          else
            if EMPTY_ANSWERS_RESULT.key?(method)
              EMPTY_ANSWERS_RESULT[method]
            else
              send_message(jsonrpc: "2.0", id: id, error: { code: METHOD_NOT_FOUND, message: "method not found: #{method}" })
              return
            end
          end
        send_message(jsonrpc: "2.0", id: id, result: result)
      end

      def notify(method, params)
        case method
        when "exit" then @exit = true
        when "textDocument/didOpen"
          doc = params["textDocument"] || {}
          store(doc["uri"], doc["text"], doc["version"])
        when "textDocument/didChange"
          changes = Array(params["contentChanges"])
          text = changes.empty? ? nil : changes.last&.fetch("text", nil)
          store(params.dig("textDocument", "uri"), text, params.dig("textDocument", "version")) unless text.nil?
        when "textDocument/didSave"
          uri = params.dig("textDocument", "uri")
          held = @documents[uri]
          store(uri, params["text"] || held&.text, held&.version)
        when "textDocument/didClose"
          uri = params.dig("textDocument", "uri")
          @documents.delete(uri)
          Sources.delete(uri_to_path(uri)) if uri
          if view?(uri)
            refresh_dependents(uri) # the DSL files that render it read the file on disk again
          else
            publish(uri, [], nil)
          end
        end
      end

      def initialize_result
        {
          capabilities: {
            textDocumentSync: { openClose: true, change: 1, save: { includeText: false } },
            hoverProvider: true,
            completionProvider: { triggerCharacters: [":"] }
          },
          serverInfo: { name: "axum_dsl", version: AxumDsl::VERSION }
        }
      end

      # -- the documents ------------------------------------------------------------------------------------

      # A document was opened, changed or saved: hold the new text, compile it, publish what the compiler said,
      # and re-check every other open document (a binding or a fragment one file reads feeds the others).
      def store(uri, text, version)
        return if uri.nil? || text.nil?

        @documents[uri] = Document.new(text, version, nil)
        if view?(uri)
          # A view is no DSL file: it is held so its unsaved text stands in for the file (Views.load reads
          # Sources), and the open DSL files are re-diagnosed against it.
          refresh_dependents(uri)
          return
        end
        document = analyse(uri)
        @documents[uri] = document
        publish(uri, diagnostics_for(document.analysis), version)
        refresh_dependents(uri)
      end

      # Analyses one open document with every open document standing in for its path, so a binding, a fragment
      # or a rust_file is read from its buffer too, then puts the shared table back.
      def analyse(uri)
        doc = @documents[uri]
        table = @documents.to_h { |u, d| [uri_to_path(u), d.text] }
        analysis = Sources.with_all(table) { Analysis.new(uri_to_path(uri), doc.text) }
        Document.new(doc.text, doc.version, analysis)
      end

      # Every other open document is re-analysed and republished: a changed binding, fragment or rust_file is
      # what its siblings compile against.
      def refresh_dependents(changed_uri)
        @documents.each do |uri, doc|
          next if uri == changed_uri || view?(uri)

          refreshed = analyse(uri)
          @documents[uri] = refreshed
          publish(uri, diagnostics_for(refreshed.analysis), doc.version)
        end
      end

      # A view is an `.html` file under the views folder, which a `render` reads at compile time. It is held
      # like a DSL document (its buffer stands in for the file) but is not compiled or diagnosed itself.
      def view?(uri) = uri.to_s.end_with?(".html")

      def diagnostics_for(analysis)
        analysis.diagnostics.map { |d| lsp_diagnostic(analysis, d) }
      end

      def publish(uri, diagnostics, version)
        return if uri.nil?

        params = { uri: uri, diagnostics: diagnostics }
        params[:version] = version if version
        send_message(jsonrpc: "2.0", method: "textDocument/publishDiagnostics", params: params)
      end

      # The diagnostic's line text is what the UTF-16 columns are counted in.
      def lsp_diagnostic(analysis, diag)
        text = analysis.line_text(diag.line)
        {
          range: {
            start: { line: diag.line - 1, character: Position.to_lsp(text, diag.col) },
            end: { line: diag.line - 1, character: Position.to_lsp(text, diag.end_col) }
          },
          severity: diag.severity,
          source: "axum_dsl",
          code: diag.code,
          message: diag.message,
          data: { suggestions: diag.suggestions }
        }.compact
      end

      # -- requests -----------------------------------------------------------------------------------------

      # The analysis of the open version, or a fresh one from the buffer or disk for a document not open here.
      def analysis_for(uri)
        return nil if uri.nil?

        doc = @documents[uri]
        return doc.analysis if doc

        path = uri_to_path(uri)
        Analysis.new(path, Sources[path] || File.read(path, encoding: "UTF-8"))
      rescue SystemCallError
        nil
      end

      def hover(params)
        analysis = analysis_for(params.dig("textDocument", "uri"))
        return nil if analysis.nil?

        position = params["position"] || {}
        guarded(nil) { Hover.at(analysis, position["line"].to_i, position["character"].to_i) }
      end

      def completion(params)
        analysis = analysis_for(params.dig("textDocument", "uri"))
        return { isIncomplete: false, items: [] } if analysis.nil?

        position = params["position"] || {}
        items = guarded([]) { Completion.at(analysis, position["line"].to_i, position["character"].to_i) }
        { isIncomplete: false, items: items || [] }
      end

      # A collaborator's bug must not take the editor down: report it and answer the fallback.
      def guarded(fallback)
        yield
      rescue StandardError => e
        report("#{e.class}: #{e.message}")
        fallback
      end
    end
  end
end
