# frozen_string_literal: true

# The type-derivation graph (lib/axum_dsl/type_graph.rb): what takes its type from what, collected while the compiler
# derives. Pinned here on small apps by the exact set of nodes a change reaches, that a compile with a graph emits the
# same Rust as one without, that the graph is acyclic, and the command line and language server answers built on it.
# No cargo and no HTTP.
#
#   ruby -Ilib test/test_type_graph.rb     (make t-type-graph)
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require "axum_dsl"

class TestTypeGraph < Minitest::Test
  EXE = File.expand_path("../exe/axum_dsl", __dir__)

  # `flag:` fills an i64 field from a bool column and `mine:` from a bool expr (both widen); `RoomName` is derived.
  APP = <<~RB
    server "graph", version: "0.1.0"
    set :port, 8080
    database :sqlite, path: "x.db"

    table :rooms do
      field :id, :i64
      field :name, :string
      field :archived, :bool
    end

    expr :owned_by, of: :t, type: :bool, args: { who: :i64 }, sql: "{t}.id = :who"

    record :RoomFlag do
      field :id, :i64
      field :flag, :i64
      field :mine, :i64
    end

    model :Room, table: :rooms do
      query :flags, args: { u: :i64 }, returns: list(:RoomFlag) do
        select(:id, flag: :archived, mine: expr(:owned_by, who: arg(:u)))
      end

      query :names, args: {}, returns: list(:RoomName) do
        select(:id, :name)
      end
    end

    get "/flags" do
      json(flags(u: 1))
    end

    get "/names" do
      json(names)
    end
  RB

  ATTACHED = <<~RB
    server "attached", version: "0.1.0"
    set :port, 8080
    database :sqlite, path: "x.db"
    setting :storage, env: "STORAGE_PATH", default: "storage/files"

    table :users do
      field :id, :i64
      field :name, :string
      field :updated_at, :time
    end

    table :active_storage_blobs do
      field :id, :i64
      field :key, :string
      field :filename, :string
      field :content_type, :string
      field :metadata, :string
      field :service_name, :string
      field :byte_size, :i64
      field :checksum, :string
      field :created_at, :time
    end

    table :active_storage_attachments do
      field :id, :i64
      field :name, :string
      field :record_type, :string
      field :record_id, :i64
      field :blob_id, :i64
      field :created_at, :time
    end

    model :Blob, table: :active_storage_blobs do
    end

    model :Attachment, table: :active_storage_attachments do
      belongs_to :blob, model: :Blob
    end

    model :User, table: :users do
      has_one_attached :avatar

      query :with_avatar, args: {}, returns: :i64 do
        where(attached(:avatar)).count
      end
    end

    get "/counts" do
      text(with_avatar.to_s)
    end

    params :Form do
      field :id, :i64, in: :path
      field :avatar, :upload, in: :form, name: "user[avatar]"
    end

    patch "/users/:id", params: :Form do
      stored = params[:avatar]&.store_file(setting(:storage))
      rows = transaction do
        attach(:avatar, params[:id], stored)
      end
      text(rows.to_s)
    end
  RB

  def with_app(src, name = "graph")
    Dir.mktmpdir("type_graph") do |dir|
      file = File.join(dir, "#{name}.axum.rb")
      File.write(file, src)
      yield file
    end
  end

  def graph_of(file)
    graph = AxumDsl::TypeGraph.new
    AxumDsl.read(file, graph: graph)
    graph
  end

  # --- the graph itself --------------------------------------------------------------------------------------------

  def test_derive_makes_nodes_and_edges_and_impact_follows_them
    g = AxumDsl::TypeGraph.new
    g.declare("column:t.a", type: "i64")
    g.derive("field:R.a", from: ["column:t.a"], rule: "select", type: "i64")
    g.derive("field:S.a", from: ["field:R.a"], rule: "select")
    g.derive("field:S.a", from: ["column:t.a"], rule: "select") # another source, same node
    assert_equal %w[field:R.a field:S.a], g.impact("column:t.a")
    assert_equal %w[field:S.a], g.impact("field:R.a")
    assert_equal [], g.impact("field:S.a")
    assert_equal %w[column:t.a field:R.a], g.sources("field:S.a").map(&:from).sort
    assert_equal :derived, g.node("field:R.a").origin
    assert_equal :declared, g.node("column:t.a").origin
    assert g.acyclic?
  end

  def test_a_cycle_is_found
    g = AxumDsl::TypeGraph.new
    g.derive("a:x", from: ["b:x"], rule: "r")
    g.derive("b:x", from: ["a:x"], rule: "r")
    refute g.acyclic?
  end

  def test_forget_drops_a_node_and_its_edges
    g = AxumDsl::TypeGraph.new
    g.derive("query:q", from: ["attached:U.a"], rule: "r")
    g.forget("query:q")
    assert_nil g.node("query:q")
    assert_empty g.edges
  end

  def test_the_path_param_hook_registers_a_param_from_its_derived_data
    host = Class.new do
      include AxumDsl::TypeGraph::Sites
      public :graph_path_param

      def initialize(graph) = @graph = graph
    end
    g = AxumDsl::TypeGraph.new
    field = { "name" => "id", "type" => "i64", "derived" => { "from" => "rooms.id", "via" => "resources :rooms", "at" => "/x/app.axum.rb:12" } }
    host.new(g).graph_path_param("GET /rooms/:id", field, nil)
    assert_equal ["column:rooms.id"], g.sources("param:GET /rooms/:id.id").map(&:from)
    assert_equal "resources :rooms", g.sources("param:GET /rooms/:id.id").first.rule
    host.new(nil).graph_path_param("GET /rooms/:id", field, nil) # no graph: nothing happens
  end

  def test_a_resources_member_takes_its_id_from_the_models_column
    src = <<~RB
      server "graph", version: "0.1.0"
      table :rooms do
        field :id, :i64
      end
      model :Room, table: :rooms do
      end
      controller "Rooms" do
        def show
          text("x")
        end
      end
      resources :rooms, only: [:show]
    RB
    with_app(src) do |file|
      g = graph_of(file)
      assert_equal [["column:rooms.id", "resources :rooms"]], g.sources("param:GET /rooms/:id.id").map { |e| [e.from, e.rule] }
      assert_equal "i64", g.node("param:GET /rooms/:id.id").type
      assert_equal ["param:GET /rooms/:id.id"], g.impact("column:rooms.id")
    end
  end

  # --- what the compiler registers ---------------------------------------------------------------------------------

  def test_impact_of_a_column_is_exactly_the_record_fields_that_select_it
    with_app(APP) do |file|
      g = graph_of(file)
      assert_equal %w[field:RoomFlag.id field:RoomName.id], g.impact("column:rooms.id")
      assert_equal %w[field:RoomName.name], g.impact("column:rooms.name")
      assert_equal %w[field:RoomFlag.flag], g.impact("column:rooms.archived")
      assert_equal %w[field:RoomFlag.mine], g.impact("expr:owned_by")
      assert g.acyclic?
    end
  end

  def test_a_bool_into_an_i64_field_is_a_widening_edge
    with_app(APP) do |file|
      g = graph_of(file)
      assert_equal [["column:rooms.archived", "widen bool->i64"]], g.sources("field:RoomFlag.flag").map { |e| [e.from, e.rule] }
      assert_equal [["expr:owned_by", "widen bool->i64"]], g.sources("field:RoomFlag.mine").map { |e| [e.from, e.rule] }
      assert_equal [["column:rooms.id", "select"]], g.sources("field:RoomFlag.id").map { |e| [e.from, e.rule] }
      assert_equal "i64", g.node("field:RoomFlag.flag").type
      assert_equal "string", g.node("column:rooms.name").type
    end
  end

  def test_has_one_attached_derivatives_come_from_the_declaration
    with_app(ATTACHED, "attached") do |file|
      g = graph_of(file)
      expected = %w[assoc:User.avatar_attachment assoc:User.avatar_blob query:attach_user_avatar query:detach_user_avatar
                    query:insert_user_avatar_blob query:touch_user_avatar]
      assert_equal expected, g.impact("attached:User.avatar")
      node = g.node("attached:User.avatar")
      assert_equal File.realpath(file), node.file
      assert_equal 1, g.sources("assoc:User.avatar_blob").size
      assert_equal "has_one_attached", g.sources("assoc:User.avatar_blob").first.rule
      assert g.acyclic?
    end
  end

  def test_a_statement_nothing_calls_is_not_in_the_graph
    src = ATTACHED.sub(/patch "\/users.*?\nend\n/m, "").sub(/params :Form.*?\nend\n/m, "").sub(/setting :storage.*\n/, "")
    with_app(src, "attached") do |file|
      g = graph_of(file)
      assert_empty(g.nodes.keys.grep(/\Aquery:/))
    end
  end

  def test_the_emitted_rust_is_the_same_with_and_without_a_graph
    [APP, ATTACHED].each do |src|
      with_app(src) do |file|
        plain = AxumDsl::Emit.files(AxumDsl.read(file), file)
        graphed = AxumDsl::Emit.files(AxumDsl.read(file, graph: AxumDsl::TypeGraph.new), file)
        assert_equal plain, graphed
      end
    end
  end

  # --- the command line --------------------------------------------------------------------------------------------

  def graph_cli(file, *args)
    Open3.capture3(RbConfig.ruby, EXE, "graph", file, *args)
  end

  def test_the_graph_command_lists_why_and_impact
    with_app(APP) do |file|
      out, _err, status = graph_cli(file, "--impact", "column:rooms.id")
      assert status.success?
      assert_equal "field:RoomFlag.id\nfield:RoomName.id\n", out

      out, _err, status = graph_cli(file, "--why", "field:RoomFlag.flag")
      assert status.success?
      assert_includes out, "<- column:rooms.archived (bool"
      assert_includes out, "(widen bool->i64)"

      out, _err, status = graph_cli(file, "--format", "json", "--impact", "expr:owned_by")
      assert status.success?
      assert_equal({ "node" => "expr:owned_by", "impact" => ["field:RoomFlag.mine"] }, JSON.parse(out))

      out, _err, status = graph_cli(file, "--format", "json")
      assert status.success?
      assert_includes JSON.parse(out).fetch("edges").map { |e| e["to"] }, "field:RoomName.name"

      _out, err, status = graph_cli(file, "--why", "column:nope.id")
      refute status.success?
      assert_includes err, "no node `column:nope.id`"
    end
  end

  # --- the language server -----------------------------------------------------------------------------------------

  def analysis_of(file) = AxumDsl::Lsp::Analysis.new(file, File.read(file))

  def position_of(text, needle)
    lines = text.split("\n", -1)
    line = lines.index { |l| l.include?(needle) }
    [line, lines[line].index(needle)]
  end

  def test_hover_shows_the_derivation
    with_app(APP) do |file|
      analysis = analysis_of(file)
      line, col = position_of(APP, "query :flags")
      value = AxumDsl::Lsp::Hover.at(analysis, line, col).dig(:contents, :value)
      assert_includes value, "`field:RoomFlag.flag`"
      assert_includes value, "`column:rooms.archived` (widen bool->i64)"
    end
  end

  def test_definition_jumps_to_the_source_and_references_come_back
    with_app(APP) do |file|
      analysis = analysis_of(file)
      line, col = position_of(APP, "query :flags")
      target = AxumDsl::Lsp::Definition.at(analysis, line, col)
      assert target, "definition answers a location"
      declared, = position_of(APP, "field :archived, :bool") # the first field (by id) of the cursor's query takes its type from this column
      assert_equal declared, target[:range][:start][:line]

      line, col = position_of(APP, "field :archived, :bool")
      refs = AxumDsl::Lsp::Definition.references(analysis, line, col)
      query_line, = position_of(APP, "query :flags")
      assert_equal [query_line], refs.map { |r| r[:range][:start][:line] }
    end
  end
end
