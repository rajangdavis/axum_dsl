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
require "fileutils"
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

  # -- a project of many files: the open file is a fragment, the root is found and compiled from ----------------

  APP = <<~'RB'
    server "app", version: "0.1.0"
    database :sqlite, path: "k.sqlite3"

    table :rooms do
      field :id, :i64
      field :name, :string, optional: true
      field :kind, :string
    end

    use_dsl "models/thing.axum.rb"
    use_dsl "models/room.axum.rb"
    use_dsl "controllers/admin/things.axum.rb"
  RB

  THING_MODEL = <<~'RB'
    model do
      record :Thing do
        field :id, :i64
      end
      query :thing, args: { id: :i64 }, returns: :Thing?, sql: "SELECT 1 AS id WHERE :id = 1"
      def thing_or_none(id)
        thing(id: id)
      end
    end
  RB

  ROOM_MODEL = <<~'RB'
    model "Room", table: :rooms do
      query :a_room, args: { id: :i64 }, returns: :RoomName? do
        where(id: arg(:id)).select(:id, name: coalesce(:name, ""))
      end
    end
  RB

  THINGS_CONTROLLER = <<~'RB'
    controller do
      params :Pick do
        field :id, :i64, in: :query
      end
      before :guard, only: [:show]
      get "/things", action: :index do
        "all"
      end
      get "/things/one", action: :show do
        t = thing_or_none(1)
        t.nil? ? "none" : "one"
      end
      get "/things/room", action: :room do
        r = a_room(id: 1)
        r.nil? ? "no room" : "room"
      end
      get "/things/pick", params: :Pick, action: :pick do
        n = params[:id]
        "picked #{n}"
      end
      get "/things/home", action: :home do
        render :home
      end
      def guard
        return head(403) if thing_or_none(1).nil?
      end
    end
  RB

  def test_a_fragment_is_compiled_from_its_root_and_hover_and_definition_see_the_whole_project
    Dir.mktmpdir("axum_lsp_root") do |dir|
      write_project(dir, "app.axum.rb" => APP, "models/thing.axum.rb" => THING_MODEL, "models/room.axum.rb" => ROOM_MODEL,
                    "controllers/admin/things.axum.rb" => THINGS_CONTROLLER, "views/home.html" => "<p>home</p>\n")
      ctl = "file://#{File.join(dir, "controllers/admin/things.axum.rb")}"
      thing = "file://#{File.join(dir, "models/thing.axum.rb")}"
      room = "file://#{File.join(dir, "models/room.axum.rb")}"
      broken_room = ROOM_MODEL.sub("query :a_room", "quer :a_room")

      messages, status, err = session(
        request(1, "initialize", processId: nil, rootUri: nil, capabilities: {}),
        notification("textDocument/didOpen", textDocument: { uri: ctl, languageId: "ruby", version: 1, text: THINGS_CONTROLLER }),
        hover_at(2, ctl, THINGS_CONTROLLER, "n = params", 0),                     # a local
        hover_at(3, ctl, THINGS_CONTROLLER, "params[:id]", 0),                    # a parameter
        hover_at(4, ctl, THINGS_CONTROLLER, "a_room(id: 1)", 0),                  # a relation-block statement
        hover_at(5, ctl, THINGS_CONTROLLER, "params :Pick", 0),                   # a declaration, as before
        definition_at(6, ctl, THINGS_CONTROLLER, "a_room(id: 1)", 0),             # a statement, in another file
        definition_at(7, ctl, THINGS_CONTROLLER, "thing_or_none(1)", 0),          # a def, in another file
        definition_at(8, ctl, THINGS_CONTROLLER, "params: :Pick", 9),             # a params group
        definition_at(9, ctl, THINGS_CONTROLLER, "before :guard", 8),             # a filter: its def
        definition_at(10, ctl, THINGS_CONTROLLER, "render :home", 8),             # a view
        definition_at(11, ctl, THINGS_CONTROLLER, "\"all\"", 1),                  # nothing
        notification("textDocument/didOpen", textDocument: { uri: thing, languageId: "ruby", version: 1, text: THING_MODEL }),
        hover_at(12, thing, THING_MODEL, "thing(id: id)", 0),                     # a sql: statement
        definition_at(13, thing, THING_MODEL, "thing(id: id)", 0),
        notification("textDocument/didOpen", textDocument: { uri: room, languageId: "ruby", version: 1, text: broken_room }),
        request(99, "shutdown"),
        notification("exit")
      )
      assert status.success?, "the server exited #{status.exitstatus}:\n#{err}"
      assert_empty err, "the server wrote to stderr:\n#{err}"
      assert response(messages, 1).dig("result", "capabilities", "definitionProvider")

      published = messages.select { |m| m["method"] == "textDocument/publishDiagnostics" }
      first = published.first
      assert_equal ctl, first.dig("params", "uri")
      assert_empty first.dig("params", "diagnostics"), "a controller file compiled from its root is not an error"

      # -- L1: the inferred type of a local and of a parameter --
      local = hover_text(messages, 2)
      assert_includes local, "**`n`** - local"
      assert_includes local, "`Integer (i64)`"
      assert_equal line_of(THINGS_CONTROLLER, "n = params"), response(messages, 2).dig("result", "range", "start", "line")
      param = hover_text(messages, 3)
      assert_includes param, "**`id`** - parameter"
      assert_includes param, "`Integer (i64)`"

      # -- L2: a statement written as a relation shows the SQL the compiler rendered --
      relation = hover_text(messages, 4)
      assert_includes relation, "**`a_room`** - query"
      assert_includes relation, "id: i64"
      assert_includes relation, "`:RoomName?`"
      assert_includes relation, "models/room.axum.rb:2"
      assert_includes relation, "```sql\nSELECT"
      assert_includes relation, "FROM rooms"
      # a declaration keeps its SIG hover
      assert_includes hover_text(messages, 5), "**`params`**"
      sql_statement = hover_text(messages, 12)
      assert_includes sql_statement, "**`thing`** - query"
      assert_includes sql_statement, "SELECT 1 AS id WHERE :id = 1"

      # -- L3 --
      statement = definition_result(messages, 6)
      assert_equal File.join(dir, "models/room.axum.rb"), statement[:path]
      assert_equal line_of(ROOM_MODEL, "query :a_room"), statement[:line]
      assert_equal File.join(dir, "models/thing.axum.rb"), definition_result(messages, 7)[:path]
      assert_equal line_of(THING_MODEL, "def thing_or_none"), definition_result(messages, 7)[:line]
      assert_equal line_of(THINGS_CONTROLLER, "params :Pick"), definition_result(messages, 8)[:line]
      assert_equal File.join(dir, "controllers/admin/things.axum.rb"), definition_result(messages, 8)[:path]
      assert_equal line_of(THINGS_CONTROLLER, "def guard"), definition_result(messages, 9)[:line]
      assert_equal File.join(dir, "views/home.html"), definition_result(messages, 10)[:path]
      assert_nil response(messages, 11)["result"]
      assert_equal line_of(THING_MODEL, "query :thing"), definition_result(messages, 13)[:line]

      # -- L0: an error in another file is that file's diagnostic, not the open file's --
      last = published.to_h { |m| [m.dig("params", "uri"), m.dig("params", "diagnostics")] }
      assert_equal [1], last.fetch(room).map { |d| d["severity"] }, "the broken file carries its own error"
      assert_includes last.fetch(room).first["message"], "unknown DSL call `quer`"
      [ctl, thing].each do |uri|
        assert_equal [3], last.fetch(uri).map { |d| d["severity"] }, "#{uri}: only a note that the compile stopped elsewhere"
        assert_equal 0, last.fetch(uri).first.dig("range", "start", "line")
        assert_includes last.fetch(uri).first["message"], "models/room.axum.rb:2"
      end
    end
  end

  CURRENT_DOC = <<~'RB'
    server "kinds", version: "0.1.0"
    setting :secret_key, env: "SECRET_KEY_BASE", secret: true
    cookies secret: :secret_key
    before :authenticate do
      return redirect("/login") if current_user.nil?
      "continue"
    end
    current :user, returns: :string?, required: :authenticate, reader: :current_user do
      cookie(:who)
    end
    get "/me" do
      current_user
    end
    get "/open", skip: [:authenticate] do
      "open"
    end
  RB

  def test_definition_of_a_current_reader_and_of_a_skipped_filter
    Dir.mktmpdir("axum_lsp_current") do |dir|
      file = File.join(dir, "kinds.axum.rb")
      File.write(file, CURRENT_DOC)
      uri = "file://#{file}"
      messages, status, err = session(
        request(1, "initialize", processId: nil, rootUri: nil, capabilities: {}),
        notification("textDocument/didOpen", textDocument: { uri: uri, languageId: "ruby", version: 1, text: CURRENT_DOC }),
        definition_at(2, uri, CURRENT_DOC, "current_user\nend", 0),
        definition_at(3, uri, CURRENT_DOC, "skip: [:authenticate]", 8),
        request(4, "shutdown"),
        notification("exit")
      )
      assert status.success?, "the server exited #{status.exitstatus}:\n#{err}"
      assert_empty err
      assert_empty messages.find { |m| m["method"] == "textDocument/publishDiagnostics" }.dig("params", "diagnostics")
      assert_equal line_of(CURRENT_DOC, "current :user"), definition_result(messages, 2)[:line]
      assert_equal line_of(CURRENT_DOC, "before :authenticate"), definition_result(messages, 3)[:line]
    end
  end

  DESTROY_DOC = <<~'RB'
    server "d", version: "0.1.0"
    set :port, 8096
    database :sqlite, path: "x.db"

    table :rooms do
      field :id, :i64
    end

    table :memberships do
      field :id, :i64
      field :room_id, :i64
    end

    model :Membership, table: :memberships do
    end

    model :Room, table: :rooms do
      has_many :memberships, dependent: :delete_all
      execute :destroy_room, args: { id: :i64 } do
        where(id: arg(:id)).destroy
      end
    end

    post "/destroy" do
      rows = transaction do
        destroy_room(id: 1)
      end
      text(rows.to_s)
    end
  RB

  def test_hover_on_a_destroy_lists_its_statements_in_order
    Dir.mktmpdir("axum_lsp_destroy") do |dir|
      file = File.join(dir, "d.axum.rb")
      File.write(file, DESTROY_DOC)
      uri = "file://#{file}"
      messages, status, err = session(
        request(1, "initialize", processId: nil, rootUri: nil, capabilities: {}),
        notification("textDocument/didOpen", textDocument: { uri: uri, languageId: "ruby", version: 1, text: DESTROY_DOC }),
        hover_at(2, uri, DESTROY_DOC, "destroy_room(id: 1)", 0),
        request(3, "shutdown"),
        notification("exit")
      )
      assert status.success?, "the server exited #{status.exitstatus}:\n#{err}"
      text = hover_text(messages, 2)
      assert_includes text, "**`destroy_room`** - execute"
      assert_includes text, "2 statements run in this order as one unit"
      members = text.index("DELETE FROM memberships")
      rooms = text.index("DELETE FROM rooms WHERE id = :id")
      refute_nil members, text
      refute_nil rooms, text
      assert_operator members, :<, rooms, "the memberships go before the room"
    end
  end

  # The cost of compiling a whole project for one open fragment, measured on Campfire when it is next to this
  # repo: the session with the fragment open minus the same session without it.
  def test_a_campfire_fragment_compiles_from_its_root_and_the_cost_is_reported
    root = File.expand_path("../../campfire_axum_dsl", __dir__)
    fragment = File.join(root, "controllers/rooms.axum.rb")
    skip "no Campfire next to this repo" unless File.file?(fragment)

    text = File.read(fragment, encoding: "UTF-8")
    uri = "file://#{fragment}"
    init = request(1, "initialize", processId: nil, rootUri: nil, capabilities: {})
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    session(init, request(2, "shutdown"), notification("exit"))
    base = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    messages, = session(init, notification("textDocument/didOpen", textDocument: { uri: uri, languageId: "ruby", version: 1, text: text }),
                        request(2, "shutdown"), notification("exit"))
    with = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    puts format("\nLSP campfire fragment: open + compile from root = %.2f s (boot alone %.2f s)", with - base, base)
    shown = messages.find { |m| m["method"] == "textDocument/publishDiagnostics" }.dig("params", "diagnostics")
    refute(shown.any? { |d| d["message"].include?("takes its name from a file") }, shown.inspect)
  end

  private

  def write_project(dir, files)
    files.each do |rel, text|
      FileUtils.mkdir_p(File.dirname(File.join(dir, rel)))
      File.write(File.join(dir, rel), text)
    end
  end

  # (line0, character) of the `delta`-th character after the first occurrence of `needle` in `text`.
  def position_of(text, needle, delta)
    index = text.index(needle) or flunk("no #{needle.inspect} in the text")
    before = text[0...(index + delta)]
    [before.count("\n"), before.length - (before.rindex("\n") ? before.rindex("\n") + 1 : 0)]
  end

  def line_of(text, needle) = position_of(text, needle, 0).first

  def hover_at(id, uri, text, needle, delta) = hover(id, uri, *position_of(text, needle, delta))

  def definition_at(id, uri, text, needle, delta)
    line, character = position_of(text, needle, delta)
    request(id, "textDocument/definition", textDocument: { uri: uri }, position: { line: line, character: character })
  end

  def hover_text(messages, id) = response(messages, id).dig("result", "contents", "value").to_s

  # {path:, line:} of a Location answer (line 0-based), the path as a path.
  def definition_result(messages, id)
    result = response(messages, id)["result"]
    refute_nil result, "no definition answered for request #{id}"
    { path: result["uri"].delete_prefix("file://"), line: result.dig("range", "start", "line") }
  end

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

require_relative "../lib/axum_dsl"

# Lsp::Root alone: how the root of a fragment is found.
class TestLspRoot < Minitest::Test
  def finder
    AxumDsl::Lsp::Root.new(glob: AxumDsl::Lsp::AxumSource::GLOB, includes: AxumDsl::Lsp::AxumSource.method(:includes),
                           root: AxumDsl::Lsp::AxumSource.method(:root?))
  end

  def project(dir, files)
    files.each do |rel, text|
      FileUtils.mkdir_p(File.dirname(File.join(dir, rel)))
      File.write(File.join(dir, rel), text)
    end
  end

  def test_the_root_is_the_first_directory_up_whose_file_splices_it_in_even_through_a_fragment
    Dir.mktmpdir("axum_root") do |dir|
      dir = File.realpath(dir)
      project(dir, "app.axum.rb" => "server \"a\", version: \"0.1.0\"\nuse_dsl \"lib/mid.axum.rb\"\n",
                   "lib/mid.axum.rb" => "fragment do\n  use_dsl \"deep.axum.rb\"\nend\n",
                   "lib/deep.axum.rb" => "fragment do\nend\n",
                   "lib/alone.axum.rb" => "fragment do\nend\n")
      roots = finder
      assert_equal File.join(dir, "app.axum.rb"), roots.find(File.join(dir, "lib/mid.axum.rb"))
      assert_equal File.join(dir, "app.axum.rb"), roots.find(File.join(dir, "lib/deep.axum.rb")), "mid.axum.rb is a fragment, not a root"
      assert_nil roots.find(File.join(dir, "lib/alone.axum.rb")), "nothing splices this file in"
    end
  end

  def test_an_open_buffer_stands_in_for_the_file_and_a_root_that_stops_splicing_is_dropped
    Dir.mktmpdir("axum_root") do |dir|
      dir = File.realpath(dir)
      project(dir, "app.axum.rb" => "use_dsl \"x.axum.rb\"\n", "x.axum.rb" => "fragment do\nend\n")
      roots = finder
      assert_equal File.join(dir, "app.axum.rb"), roots.find(File.join(dir, "x.axum.rb"))
      AxumDsl::Lsp::Sources.with(File.join(dir, "app.axum.rb"), "server \"a\", version: \"0.1.0\"\n") do
        assert_nil roots.find(File.join(dir, "x.axum.rb")), "the unsaved root no longer splices x in"
      end
    end
  end
end
