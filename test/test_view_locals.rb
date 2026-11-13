# frozen_string_literal: true

# Locals without `locals:` (docs/views.md, "Locals without locals:"): a view's names are bound from the render's
# `locals:`, else a local variable of the same name in the route, else a `view_local`. Each case compiles a small
# DSL string beside its view files and asserts on the emitted Rust, or on the refusal. No cargo and no HTTP.
#
#   ruby -Ilib test/test_view_locals.rb
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "axum_dsl"

class TestViewLocals < Minitest::Test
  HEAD = <<~RB
    server "locals", version: "0.1.0"
    set :port, 8080
  RB

  PAGE = { "home.html" => "<p>{{ title }}</p>\n" }.freeze

  def compile(source, views = PAGE)
    Dir.mktmpdir("locals") do |dir|
      views.each do |rel, text|
        FileUtils.mkdir_p(File.dirname(File.join(dir, "views", rel)))
        File.write(File.join(dir, "views", rel), text)
      end
      file = File.join(dir, "locals.axum.rb")
      File.write(file, HEAD + source)
      AxumDsl::Emit.files(AxumDsl.read(file), file)["src/main.rs"]
    end
  end

  def refusal(source, views = PAGE)
    assert_raises(AxumDsl::CompileError) { compile(source, views) }.message
  end

  def test_a_local_variable_of_the_same_name_binds_like_an_explicit_local
    implicit = compile(%(get "/" do\n  title = "Hi"\n  render :home\nend\n))
    explicit = compile(%(get "/" do\n  title = "Hi"\n  render :home, locals: { title: title }\nend\n))
    assert_equal explicit, implicit
  end

  def test_a_view_local_binds_a_name_nothing_else_gives
    main = compile(%(view_local :title do\n  "Hi"\nend\nget "/" do\n  render :home\nend\n))
    assert_includes main, 'let __vl_title = "Hi";'
  end

  def test_a_view_local_is_found_when_declared_in_a_fragment
    Dir.mktmpdir("locals") do |dir|
      FileUtils.mkdir_p(File.join(dir, "views"))
      File.write(File.join(dir, "views", "home.html"), PAGE["home.html"])
      File.write(File.join(dir, "frag.axum.rb"), %(fragment do\n  view_local :title do\n    "Hi"\n  end\nend\n))
      file = File.join(dir, "locals.axum.rb")
      File.write(file, HEAD + %(use_dsl "frag.axum.rb"\nget "/" do\n  render :home\nend\n))
      main = AxumDsl::Emit.files(AxumDsl.read(file), file)["src/main.rs"]
      assert_includes main, 'let __vl_title = "Hi";'
    end
  end

  def test_an_explicit_local_wins_over_a_view_local
    main = compile(%(view_local :title do\n  "FROM-VIEW-LOCAL"\nend\nget "/" do\n  render :home, locals: { title: "T" }\nend\n))
    refute_includes main, "FROM-VIEW-LOCAL"
    refute_includes main, "__vl_"
  end

  def test_a_name_with_no_source_is_refused_with_where_to_declare_it
    msg = refusal(%(get "/" do\n  render :home\nend\n))
    assert_includes msg, "views/home.html:1: `{{ title }}` reads a local, so the render must pass it"
    assert_includes msg, "view_local :title"
  end

  def test_a_name_that_is_a_local_variable_and_a_view_local_is_ambiguous
    msg = refusal(%(view_local :title do\n  "V"\nend\nget "/" do\n  title = "L"\n  render :home\nend\n))
    assert_includes msg, "`title` is ambiguous"
    assert_includes msg, "locals: { title: ... }"
  end

  def test_a_view_local_no_view_reads_is_not_computed
    main = compile(%(view_local :title do\n  "Hi"\nend\nview_local :other do\n  "NEVER-COMPUTED"\nend\nget "/" do\n  render :home\nend\n))
    assert_includes main, "__vl_title"
    refute_includes main, "NEVER-COMPUTED"
  end

  def test_a_view_local_a_layout_reads_is_bound_too
    views = { "home.html" => "<p>hi</p>\n", "app.html" => "<b>{{ title }}</b>{{ yield }}\n" }
    main = compile(%(view_local :title do\n  "Hi"\nend\nget "/" do\n  render :home, layout: :app\nend\n), views)
    assert_includes main, 'let __vl_title = "Hi";'
  end

  def test_the_resolution_is_reported_as_a_notice
    AxumDsl::Notify.reset!
    compile(%(view_local :title do\n  "Hi"\nend\nget "/" do\n  render :home\nend\n))
    note = AxumDsl::Notify.notes.find { |n| n.code == "N-VIEW-LOCALS" }
    refute_nil note
    assert_includes note.message, "title (view_local, line 3)"
  end

  def test_a_duplicate_view_local_is_refused
    msg = refusal(%(view_local :title do\n  "a"\nend\nview_local :title do\n  "b"\nend\nget "/" do\n  render :home\nend\n))
    assert_includes msg, "duplicate view_local `title`"
  end

  # --- page_locals -------------------------------------------------------------------------------------

  def test_a_page_locals_entry_binds_a_name
    main = compile(%(controller "C" do\n  page_locals do\n    title = "Hi"\n  end\n  get "/" do\n    render :home\n  end\nend\n))
    assert_includes main, 'let __vl_title = "Hi";'
  end

  def test_a_page_locals_entry_no_view_reads_is_not_computed
    main = compile(%(controller "C" do\n  page_locals do\n    title = "Hi"\n    other = "NEVER-COMPUTED"\n  end\n  get "/" do\n    render :home\n  end\nend\n))
    assert_includes main, "__vl_title"
    refute_includes main, "NEVER-COMPUTED"
  end

  def test_a_controller_page_locals_entry_wins_over_a_top_level_view_local
    main = compile(%(view_local :title do\n  "FROM-VIEW-LOCAL"\nend\ncontroller "C" do\n  page_locals do\n    title = "LOCAL"\n  end\n  get "/" do\n    render :home\n  end\nend\n))
    assert_includes main, 'let __vl_title = "LOCAL";'
    refute_includes main, "FROM-VIEW-LOCAL"
  end

  def test_a_page_locals_entry_does_not_see_another_page_local
    msg = refusal(%(controller "C" do\n  page_locals do\n    leaked = "L"\n    title = leaked\n  end\n  get "/" do\n    render :home\n  end\nend\n))
    assert_includes msg, "undefined local `leaked`"
  end

  def test_a_duplicate_page_locals_entry_is_refused
    msg = refusal(%(controller "C" do\n  page_locals do\n    title = "a"\n    title = "b"\n  end\n  get "/" do\n    render :home\n  end\nend\n))
    assert_includes msg, "duplicate page local `title`"
  end

  def test_a_page_locals_entry_must_be_well_shaped
    msg = refusal(%(controller "C" do\n  page_locals do\n    "not a pair"\n  end\n  get "/" do\n    render :home\n  end\nend\n))
    assert_includes msg, "page_locals takes `name = value` or `@name = value` lines"
  end

  def test_page_locals_is_reported_as_a_page_locals_notice
    AxumDsl::Notify.reset!
    compile(%(controller "C" do\n  page_locals do\n    title = "Hi"\n  end\n  get "/" do\n    render :home\n  end\nend\n))
    note = AxumDsl::Notify.notes.find { |n| n.code == "N-VIEW-LOCALS" }
    refute_nil note
    assert_includes note.message, "title (page_locals, line 5)"
  end

  def test_a_controller_view_local_is_scoped_to_that_controller
    main = compile(%(controller "C" do\n  view_local :title do\n    "LOCAL"\n  end\n  get "/" do\n    render :home\n  end\nend\n))
    assert_includes main, 'let __vl_title = "LOCAL";'
  end

  def test_a_controller_view_local_does_not_leak_to_another_controller
    msg = refusal(%(controller "A" do\n  view_local :title do\n    "A"\n  end\n  get "/a" do\n    render :home\n  end\nend\ncontroller "B" do\n  get "/b" do\n    render :home\n  end\nend\n))
    assert_includes msg, "views/home.html:1"
  end

  def test_a_top_level_page_locals_is_global
    main = compile(%(page_locals do\n  title = "G"\nend\nget "/" do\n  render :home\nend\n))
    assert_includes main, 'let __vl_title = "G";'
  end

  # --- layout_locals ------------------------------------------------------------------------------------

  def test_a_layout_locals_entry_binds_a_layout_marker
    views = { "home.html" => "<p>hi</p>\n", "app.html" => "<b>{{ layout_title }}</b>{{ yield }}\n" }
    main = compile("set :layout, :app\n" + %(layout_locals do\n  layout_title = "L"\nend\nget "/" do\n  render :home\nend\n), views)
    assert_includes main, 'let __vl_layout_title = "L";'
  end

  def test_a_page_locals_entry_the_layout_reads_is_refused
    views = { "home.html" => "<p>hi</p>\n", "app.html" => "<b>{{ layout_title }}</b>{{ yield }}\n" }
    msg = refusal("set :layout, :app\n" + %(page_locals do\n  layout_title = "L"\nend\nget "/" do\n  render :home\nend\n), views)
    assert_includes msg, "move it to `layout_locals`"
  end

  def test_a_page_locals_entry_the_page_reads_binds
    views = { "home.html" => "<p>{{ page_title }}</p>\n", "app.html" => "{{ yield }}\n" }
    main = compile("set :layout, :app\n" + %(page_locals do\n  page_title = "P"\nend\nget "/" do\n  render :home\nend\n), views)
    assert_includes main, 'let __vl_page_title = "P";'
  end

  def test_a_layout_locals_entry_may_feed_a_page
    views = { "home.html" => "<p>{{ page_title }}</p>\n", "app.html" => "{{ yield }}\n" }
    main = compile("set :layout, :app\n" + %(layout_locals do\n  page_title = "P"\nend\nget "/" do\n  render :home\nend\n), views)
    assert_includes main, 'let __vl_page_title = "P";'
  end

  def test_a_layout_locals_entry_is_reported_as_a_layout_locals_notice
    AxumDsl::Notify.reset!
    views = { "home.html" => "<p>hi</p>\n", "app.html" => "<b>{{ layout_title }}</b>{{ yield }}\n" }
    compile("set :layout, :app\n" + %(layout_locals do\n  layout_title = "L"\nend\nget "/" do\n  render :home\nend\n), views)
    note = AxumDsl::Notify.notes.find { |n| n.code == "N-VIEW-LOCALS" }
    refute_nil note
    assert_includes note.message, "layout_title (layout_locals, line 5)"
  end

  def test_a_duplicate_layout_locals_entry_is_refused
    msg = refusal(%(layout_locals do\n  title = "a"\n  title = "b"\nend\nget "/" do\n  render :home\nend\n))
    assert_includes msg, "duplicate layout local `title`"
  end

  def test_a_layout_locals_entry_is_readable_in_the_action
    main = compile(%(controller "C" do\n  layout_locals do\n    label = "L"\n  end\n  get "/" do\n    text(label)\n  end\nend\n))
    assert_includes main, 'let label = "L";'
  end

  def test_a_page_locals_entry_is_not_readable_in_the_action
    msg = refusal(%(controller "C" do\n  page_locals do\n    label = "L"\n  end\n  get "/" do\n    text(label)\n  end\nend\n))
    assert_includes msg, "unsupported call `label`"
  end

  def test_a_layout_locals_entry_the_action_reads_is_emitted_once_for_that_route
    main = compile(%(controller "C" do\n  layout_locals do\n    label = "ONLY-ONE"\n  end\n  get "/a" do\n    text(label)\n  end\n  get "/b" do\n    text("B")\n  end\nend\n))
    assert_equal 1, main.scan('let label = "ONLY-ONE";').size
  end

  # --- render ... from: record ---------------------------------------------------------------------------

  NOTE = <<~RB
    database :sqlite, path: "x.db"
    record :Note do
      field :id, :i64
      field :title, :string
      field :body, :string
    end
    query :find_note, args: { id: :i64 }, returns: :Note?, sql: "SELECT id, title, body FROM notes WHERE id = :id"
  RB

  NOTE_VIEWS = { "note.html" => "<h1>{{ title }}</h1><p>{{ body }}</p><i>{{ room }}</i>\n" }.freeze

  # Two compiles are the same text; a failure shows only the first lines that differ, never a whole main.rs.
  # Each compile runs in its own temporary directory, and the generated Rust names the source file (the statement
  # table carries `path:line`), so that directory is taken out before comparing. Order is compared too: the two
  # texts must be equal once the directory is gone, and the line lists below only say where they are not.
  def assert_same_rust(expected, actual)
    expected = expected.gsub(%r{/[^"\s]*/locals\.axum\.rb}, "locals.axum.rb")
    actual = actual.gsub(%r{/[^"\s]*/locals\.axum\.rb}, "locals.axum.rb")
    return if expected == actual

    assert_equal ["(same lines, different order)"], (expected.lines - actual.lines).first(15).map { |l| "- #{l}" } + (actual.lines - expected.lines).first(15).map { |l| "+ #{l}" }
  end

  def note_route(call)
    NOTE + %(get "/" do\n  n = find_note(id: 1) || raise("gone")\n  #{call}\nend\n)
  end

  def test_from_lowers_to_what_the_explicit_locals_spelling_does
    from = compile(note_route(%(render :note, from: n, locals: { room: "r" })), NOTE_VIEWS)
    explicit = compile(note_route(%(render :note, locals: { room: "r", title: n.title, body: n.body })), NOTE_VIEWS)
    assert_same_rust explicit, from
  end

  def test_an_explicit_local_wins_over_the_record_field
    from = compile(note_route(%(render :note, from: n, locals: { room: "r", title: "T" })), NOTE_VIEWS)
    explicit = compile(note_route(%(render :note, locals: { room: "r", title: "T", body: n.body })), NOTE_VIEWS)
    assert_same_rust explicit, from
  end

  def test_a_local_variable_that_is_also_a_record_field_is_refused
    msg = refusal(note_route(%(title = "L"\n  render :note, from: n, locals: { room: "r" })), NOTE_VIEWS)
    assert_includes msg, "views/note.html reads `title`, which is both a local variable of this route and a field of Note"
    assert_includes msg, "locals: { title: ... }"
  end

  def test_a_locals_entry_resolves_the_clash_of_a_local_variable_and_a_record_field
    from = compile(note_route(%(title = "L"\n  render :note, from: n, locals: { room: "r", title: title })), NOTE_VIEWS)
    explicit = compile(note_route(%(title = "L"\n  render :note, locals: { room: "r", title: title, body: n.body })), NOTE_VIEWS)
    assert_same_rust explicit, from
  end

  def test_a_page_locals_entry_that_is_also_a_record_field_is_refused
    route = "controller \"C\" do\n  page_locals do\n    title = \"P\"\n  end\n  get \"/\" do\n    n = find_note(id: 1) || raise(\"gone\")\n    render :note, from: n, locals: { room: \"r\" }\n  end\nend\n"
    msg = refusal(NOTE + route, NOTE_VIEWS)
    assert_includes msg, "both the `page_locals` entry `title:` and a field of Note"
  end

  def test_render_string_takes_from_too
    from = compile(note_route(%(text(render_string(:note, from: n, locals: { room: "r" })))), NOTE_VIEWS)
    explicit = compile(note_route(%(text(render_string(:note, locals: { room: "r", title: n.title, body: n.body })))), NOTE_VIEWS)
    assert_same_rust explicit, from
  end

  def test_from_a_non_record_is_refused
    msg = refusal(note_route(%(render :note, from: "x", locals: { room: "r", title: "T", body: "B" })), NOTE_VIEWS)
    assert_includes msg, "`from:` takes a record"
  end

  def test_a_name_the_record_does_not_have_is_refused_with_a_from_hint
    msg = refusal(note_route(%(render :note, from: n)), NOTE_VIEWS)
    assert_includes msg, "`{{ room }}` reads a local, so the render must pass it"
    assert_includes msg, "`from:` does not have it either: Note has no field `room`"
  end

  def test_from_on_a_view_with_no_markers_is_refused
    msg = refusal(note_route(%(render :plain, from: n)), "plain.html" => "<p>hi</p>\n")
    assert_includes msg, "has no markers"
  end

  # --- instance variables: `@x = ...` in a route, `{{ @x }}` in a view ---------------------------------------------

  IVAR_VIEWS = { "home.html" => "<p>{{ @title }}</p>\n" }.freeze

  def test_an_action_ivar_binds_exactly_like_the_plain_local
    ivar = compile(%(get "/" do\n  @title = "Hi"\n  render :home\nend\n), IVAR_VIEWS)
    plain = compile(%(get "/" do\n  title = "Hi"\n  render :home\nend\n), PAGE)
    assert_equal plain, ivar
  end

  def test_an_ivar_can_be_read_later_in_the_same_body
    main = compile(%(get "/" do\n  @title = "Hi"\n  shout = @title.upcase\n  render :home, locals: { shout: shout }\nend\n),
                   "home.html" => "<p>{{ @title }}{{ shout }}</p>\n")
    assert_includes main, "let title = "
  end

  def test_an_ivar_is_assigned_once
    msg = refusal(%(get "/" do\n  @title = "a"\n  @title = "b"\n  render :home\nend\n), IVAR_VIEWS)
    assert_includes msg, "`@title` is already assigned"
  end

  def test_an_ivar_and_a_local_of_the_same_name_are_refused
    msg = refusal(%(get "/" do\n  title = "a"\n  @title = "b"\n  render :home\nend\n), IVAR_VIEWS)
    assert_includes msg, "share its Rust name"
  end

  def test_an_ivar_no_render_reads_is_refused
    msg = refusal(%(get "/" do\n  @title = "Hi"\n  @extra = "x"\n  render :home\nend\n), IVAR_VIEWS)
    assert_includes msg, "`@extra`"
    assert_includes msg, "make it a plain local"
  end

  def test_a_view_reading_an_unassigned_ivar_is_refused
    msg = refusal(%(get "/" do\n  render :home\nend\n), IVAR_VIEWS)
    assert_includes msg, "`{{ @title }}` reads an instance variable that nothing assigns"
    assert_includes msg, "assign `@title` in the action"
  end

  def test_a_bare_view_name_does_not_bind_an_ivar
    msg = refusal(%(get "/" do\n  @title = "Hi"\n  render :home\nend\n), PAGE)
    assert_includes msg, "`{{ title }}` reads a local"
  end

  def test_an_ivar_view_name_does_not_bind_a_plain_local
    msg = refusal(%(get "/" do\n  title = "Hi"\n  render :home\nend\n), IVAR_VIEWS)
    assert_includes msg, "reads an instance variable that nothing assigns"
  end

  def test_explicit_locals_feed_an_ivar_marker
    main = compile(%(get "/" do\n  render :home, locals: { title: "T" }\nend\n), IVAR_VIEWS)
    refute_includes main, "__vl_"
  end

  def test_a_layout_locals_ivar_binds_like_the_plain_entry
    views = { "home.html" => "<p>hi</p>\n", "app.html" => "<b>{{ @title }}</b>{{ yield }}\n" }
    plain_views = { "home.html" => "<p>hi</p>\n", "app.html" => "<b>{{ title }}</b>{{ yield }}\n" }
    ivar = compile(%(controller "C" do\n  layout_locals do\n    @title = "Hi"\n  end\n  get "/" do\n    render :home, layout: :app\n  end\nend\n), views)
    plain = compile(%(controller "C" do\n  layout_locals do\n    title = "Hi"\n  end\n  get "/" do\n    render :home, layout: :app\n  end\nend\n), plain_views)
    assert_equal plain, ivar
  end

  def test_two_writers_of_one_ivar_are_refused_naming_both
    msg = refusal(%(controller "C" do\n  layout_locals do\n    @title = "L"\n  end\n  get "/" do\n    @title = "A"\n    render :home\n  end\nend\n), IVAR_VIEWS)
    assert_includes msg, "two writers"
    assert_includes msg, "layout_locals"
  end

  def test_an_ivar_does_not_fire_the_view_locals_notice
    AxumDsl::Notify.reset!
    compile(%(get "/" do\n  @title = "Hi"\n  render :home\nend\n), IVAR_VIEWS)
    assert_nil AxumDsl::Notify.notes.find { |n| n.code == "N-VIEW-LOCALS" }
  end

  def test_the_type_graph_links_an_ivar_to_the_view_that_reads_it
    Dir.mktmpdir("locals") do |dir|
      FileUtils.mkdir_p(File.join(dir, "views"))
      File.write(File.join(dir, "views", "home.html"), IVAR_VIEWS["home.html"])
      file = File.join(dir, "locals.axum.rb")
      File.write(file, HEAD + %(controller "C" do\n  get "/" do\n    @title = "Hi"\n    render :home\n  end\nend\n))
      g = AxumDsl::TypeGraph.new
      AxumDsl.read(file, graph: g)
      view = g.nodes.keys.find { |id| id.start_with?("view:views/home.html.") }
      refute_nil view
      assert_equal ["view input"], g.sources(view).map(&:rule)
      assert g.sources(view).first.from.start_with?("ivar:C#")
      src = g.node(g.sources(view).first.from)
      assert_includes g.hover_markdown(src.file, src.line, src.col).to_s, view
    end
  end
end

