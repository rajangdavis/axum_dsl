# frozen_string_literal: true

# L5 for the language server: `ruby exe/axum_dsl lsp` as a real process over stdio, the way an editor talks to
# it. It is started as a child, fed a Content-Length framed session, and its stdout is read back and parsed as
# frames.
#
# The buffer it is sent differs from the file on disk, so the diagnostics it publishes can only have come from
# the buffer: that is the difference between a language server and a syntax checker, and this test fails when it
# regresses. A later didChange sends the valid text back, and the diagnostics must clear.
#
# This is a Ruby test rather than a shell script (as rmcp_dsl's test/e2e_lsp.sh is) for the framing check: the
# whole of stdout is parsed strictly - every byte must be inside a Content-Length frame and every frame must be
# one JSON-RPC message - so anything the server writes to stdout outside the protocol fails the test instead of
# hiding between the frames a grep would still find. It needs no cargo and no HTTP, so it lives in test/test_*.rb
# and runs in the `test-ruby` gate (`make check-fast`); `make lsp` runs it alone.
require "minitest/autorun"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

class TestLsp < Minitest::Test
  EXE = File.expand_path("../exe/axum_dsl", __dir__)

  # A valid service, written to disk and sent as the buffer's first version.
  SOURCE = <<~RB
    server "svc", version: "0.1.0"
    set :port, 8099

    params :Echo do
      field :message, :string, in: :query, description: "Text to echo back"
    end

    get "/echo", params: :Echo, description: "Echo the message back" do
      text(params[:message])
    end
  RB

  # One spelling away from what is on disk: the compiler refuses it and names `port`. A server that read the
  # disk would publish nothing at all for this buffer.
  BROKEN = SOURCE.sub("set :port", "set :prt")

  SET_LINE = 1     # 0-based line of `set :port`
  TOP_LINE = 2     # the blank line between `set` and `params`: the top level
  PARAMS_LINE = 3  # `params :Echo do`
  FIELD_LINE = 4   # the field inside it
  GET_LINE = 7     # `get "/echo", ... do`

  def test_the_language_server_as_a_process
    Dir.mktmpdir("axum_lsp") do |dir|
      file = File.join(dir, "svc.axum.rb")
      File.write(file, SOURCE)
      uri = "file://#{file}"

      messages, status, err = session(
        request(1, "initialize", processId: nil, rootUri: nil, capabilities: {}),
        notification("initialized"),
        notification("textDocument/didOpen",
                     textDocument: { uri: uri, languageId: "ruby", version: 1, text: BROKEN }),
        hover(2, uri, PARAMS_LINE, 1),
        completion(3, uri, FIELD_LINE, 2),
        completion(4, uri, TOP_LINE, 0),
        hover(5, uri, GET_LINE, 1),
        notification("textDocument/didChange",
                     textDocument: { uri: uri, version: 2 }, contentChanges: [{ text: SOURCE }]),
        request(6, "shutdown"),
        notification("exit")
      )

      assert status.success?, "the server exited #{status.exitstatus}:\n#{err}"
      assert_empty err, "the server wrote to stderr:\n#{err}"

      # -- the handshake says what it can do --
      init = response(messages, 1)
      caps = init.dig("result", "capabilities")
      assert_equal true, caps["hoverProvider"]
      assert caps["completionProvider"], "initialize must advertise completionProvider"
      assert caps.dig("textDocumentSync", "openClose"), "initialize must advertise document sync"
      assert_equal "axum_dsl", init.dig("result", "serverInfo", "name")

      # -- diagnostics come from the buffer, not the disk --
      published = messages.select { |m| m["method"] == "textDocument/publishDiagnostics" }
      refute_empty published, "the server published no diagnostics at all"
      assert_equal [uri], published.map { |m| m.dig("params", "uri") }.uniq,
                   "diagnostics must be published for the document that was opened"
      first = published.first
      assert_equal 1, first.dig("params", "version")
      refute_empty first.dig("params", "diagnostics"), "a buffer one character from the disk must be refused"
      broken = first.dig("params", "diagnostics").first
      assert_equal "axum_dsl", broken["source"]
      assert_equal 1, broken["severity"], "a compile error is severity 1"
      assert_equal SET_LINE, broken.dig("range", "start", "line"), "the error must be reported on its own line"
      assert_operator broken.dig("range", "end", "character"), :>, broken.dig("range", "start", "character"),
                      "the diagnostic must underline something"
      assert_includes broken["message"], "did you mean `port`"
      assert_equal ["port"], broken.dig("data", "suggestions")

      # -- and a buffer that becomes valid is cleared --
      last = published.last
      assert_equal 2, last.dig("params", "version")
      assert_empty last.dig("params", "diagnostics"), "a valid buffer must clear the diagnostics"

      # -- hover answers from SIG, over a declaration and over its arguments --
      params_hover = response(messages, 2).dig("result", "contents", "value").to_s
      assert_includes params_hover, "**`params`**"
      assert_includes params_hover, "field", "hover over `params` must name what its block holds"
      assert_includes params_hover, "the top level"
      get_hover = response(messages, 5).dig("result", "contents", "value").to_s
      assert_includes get_hover, "[params:]"
      assert_includes get_hover, "[description:]"

      # -- completion offers the declarations of the context --
      in_params = response(messages, 3).dig("result", "items").map { |i| i["label"] }
      assert_includes in_params, "field"
      refute_includes in_params, "get", "a route is not a declaration inside a params block"
      at_top = response(messages, 4).dig("result", "items").map { |i| i["label"] }
      assert_includes at_top, "get"
      assert_includes at_top, "params"
      refute_includes at_top, "field", "a field is not a declaration at the top level"

      # -- shutdown is answered before exit --
      assert_nil response(messages, 6)["result"]
      assert_equal "2.0", response(messages, 6)["jsonrpc"]
    end
  end

  # A page that renders a view: the view is a `.html` file under the views folder, which the compiler reads when
  # it compiles the DSL file, so an edit to the view must re-diagnose the DSL document that renders it. Only
  # the unsaved view text breaks the page here (the file on disk stays valid), the way the DSL test above only
  # breaks the buffer.
  VIEW_DSL = <<~RB
    server "page", version: "0.1.0"
    set :port, 8098

    get "/" do
      render :home, locals: { who: "you" }
    end
  RB
  VIEW_OK = "<p>hello {{ who }}</p>\n"
  VIEW_BROKEN = "<p>hello {{ who</p>\n"
  RENDER_LINE = 4 # 0-based line of `render`

  def test_a_view_edit_rediagnoses_the_dsl_file_that_renders_it
    Dir.mktmpdir("axum_lsp_view") do |dir|
      Dir.mkdir(File.join(dir, "views"))
      file = File.join(dir, "page.axum.rb")
      view = File.join(dir, "views", "home.html")
      File.write(file, VIEW_DSL)
      File.write(view, VIEW_OK)
      uri = "file://#{file}"
      view_uri = "file://#{view}"

      messages, status, err = session(
        request(1, "initialize", processId: nil, rootUri: nil, capabilities: {}),
        notification("initialized"),
        notification("textDocument/didOpen",
                     textDocument: { uri: uri, languageId: "ruby", version: 1, text: VIEW_DSL }),
        notification("textDocument/didOpen",
                     textDocument: { uri: view_uri, languageId: "html", version: 1, text: VIEW_OK }),
        notification("textDocument/didChange",
                     textDocument: { uri: view_uri, version: 2 }, contentChanges: [{ text: VIEW_BROKEN }]),
        notification("textDocument/didChange",
                     textDocument: { uri: view_uri, version: 3 }, contentChanges: [{ text: VIEW_OK }]),
        request(2, "shutdown"),
        notification("exit")
      )

      assert status.success?, "the server exited #{status.exitstatus}:\n#{err}"
      assert_empty err, "the server wrote to stderr:\n#{err}"

      published = messages.select { |m| m["method"] == "textDocument/publishDiagnostics" }
      assert_equal [uri], published.map { |m| m.dig("params", "uri") }.uniq,
                   "a view is not compiled itself, so diagnostics go to the DSL document only"
      # open DSL, open view, break the view, repair the view: one publish for the DSL file each time
      counts = published.map { |m| m.dig("params", "diagnostics").size }
      assert_equal [0, 0], counts.first(2), "the page is valid until the view is changed"
      broken = published[2].dig("params", "diagnostics")
      refute_empty broken, "a view edited to an unclosed marker must re-diagnose the DSL file that renders it"
      assert_includes broken.first["message"], "never closed"
      assert_equal RENDER_LINE, broken.first.dig("range", "start", "line"), "the error is reported on the `render`"
      assert_empty published.last.dig("params", "diagnostics"), "repairing the view must clear the diagnostic"
    end
  end

  private

  # Starts the server, writes every frame in order, closes its stdin, and returns [messages, status, stderr].
  # Closing stdin is also what ends a server that never got an `exit`, so the read cannot hang.
  def session(*frames)
    stdin, stdout, stderr, wait = Open3.popen3(RbConfig.ruby, EXE, "lsp")
    frames.each { |f| stdin.write(f) }
    stdin.close
    out = stdout.read
    err = stderr.read
    [parse_frames(out), wait.value, err]
  end

  # Every byte of stdout must be inside a Content-Length frame and every frame must be one JSON-RPC message.
  # A `puts` anywhere in the server, a truncated frame or a stray byte fails here.
  def parse_frames(bytes)
    messages = []
    rest = bytes.dup
    until rest.empty?
      head = /\AContent-Length: (\d+)\r\n\r\n/.match(rest)
      flunk "stdout is not a Content-Length frame stream; it starts #{rest.byteslice(0, 80).inspect}" if head.nil?

      length = head[1].to_i
      body = rest.byteslice(head[0].bytesize, length).to_s
      flunk "stdout ends inside a frame (Content-Length #{length}, #{body.bytesize} bytes left)" if body.bytesize != length

      message = begin
        JSON.parse(body)
      rescue JSON::ParserError => e
        flunk "a frame is not JSON (#{e.message}): #{body.byteslice(0, 120).inspect}"
      end
      flunk "a frame is not JSON-RPC 2.0: #{message.inspect}" unless message["jsonrpc"] == "2.0"
      messages << message
      rest = rest.byteslice(head[0].bytesize + length, rest.bytesize).to_s
    end
    messages
  end

  def response(messages, id)
    found = messages.find { |m| m["id"] == id }
    refute_nil found, "no response with id #{id}; saw #{messages.map { |m| m['method'] || "id=#{m['id']}" }.inspect}"
    found
  end

  def frame(object)
    body = JSON.generate(object)
    "Content-Length: #{body.bytesize}\r\n\r\n#{body}"
  end

  def request(id, method, **params)
    frame({ jsonrpc: "2.0", id: id, method: method, params: params })
  end

  def notification(method, **params)
    frame({ jsonrpc: "2.0", method: method, params: params })
  end

  def hover(id, uri, line0, character)
    request(id, "textDocument/hover", textDocument: { uri: uri }, position: { line: line0, character: character })
  end

  def completion(id, uri, line0, character)
    request(id, "textDocument/completion", textDocument: { uri: uri }, position: { line: line0, character: character })
  end
end
