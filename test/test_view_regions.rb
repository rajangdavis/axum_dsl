# frozen_string_literal: true

# Named layout regions: `{% content_for :nav %}...{% endcontent_for %}` in a page and `{{ yield :nav }}` in its
# layout (docs/views.md, "Named regions"). Each case compiles a small DSL string beside its view files and
# asserts on the emitted Rust, or on the refusal. No cargo and no HTTP.
#
#   ruby -Ilib test/test_view_regions.rb
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "axum_dsl"

class TestViewRegions < Minitest::Test
  HEAD = <<~RB
    server "regions", version: "0.1.0"
    set :port, 8080
  RB

  ROUTE = %(get "/" do\n  render :home, layout: :app, locals: { title: "T" }\nend\n)
  # A refusal case renders with the layout and passes no locals, so the locals rule (a local no marker reads)
  # does not answer before the region rule the case is about.
  BARE = %(get "/" do\n  render :home, layout: :app\nend\n)

  def compile(views, body: ROUTE)
    Dir.mktmpdir("regions") do |dir|
      views.each do |rel, text|
        FileUtils.mkdir_p(File.dirname(File.join(dir, "views", rel)))
        File.write(File.join(dir, "views", rel), text)
      end
      file = File.join(dir, "regions.axum.rb")
      File.write(file, HEAD + body)
      AxumDsl::Emit.files(AxumDsl.read(file), file)["src/main.rs"]
    end
  end

  def refusal(views, body: BARE)
    assert_raises(AxumDsl::CompileError) { compile(views, body: body) }.message
  end

  def app(layout, page, extra = {})
    { "app.html" => layout, "home.html" => page }.merge(extra)
  end

  LAYOUT = "<head>{{ yield :head }}</head><main>{{ yield }}</main><nav>{{ yield :nav }}</nav>\n"

  def test_a_region_is_written_where_the_layout_yields_it_and_not_in_place
    main = compile(app(LAYOUT, "{% content_for :nav %}<a>n</a>{% endcontent_for %}<p>hi</p>{% content_for :head %}<title>x</title>{% endcontent_for %}\n"),
                   body: %(get "/" do\n  render :home, layout: :app\nend\n))
    assert_includes main, 'push_str("<head><title>x</title></head><main><p>hi</p>\n</main><nav><a>n</a></nav>\n")'
  end

  def test_an_unfilled_region_is_empty
    main = compile(app(LAYOUT, "<p>hi</p>\n"), body: %(get "/" do\n  render :home, layout: :app\nend\n))
    assert_includes main, 'push_str("<head></head><main><p>hi</p>\n</main><nav></nav>\n")'
  end

  def test_a_region_is_built_like_the_view_with_its_markers_resolved
    layout = "<nav>{{ yield :nav }}</nav>{{ yield }}\n"
    page = "{% content_for :nav %}<b>{{ title }}</b>{% endcontent_for %}<p>body</p>\n"
    main = compile(app(layout, page))
    assert_operator main.index("<nav><b>"), :<, main.index("<p>body</p>"), "the region is written at the layout's yield, before the page"
    # A literal local is folded into the text, so the region's `{{ title }}` is written as `T`, once.
    assert_includes main, "<nav><b>T</b></nav><p>body</p>"
    assert_equal 1, main.scan("<b>T</b>").size
  end

  def test_a_region_filled_twice_appends_in_order
    page = "{% content_for :nav %}<i>1</i>{% endcontent_for %}<p>x</p>{% content_for :nav %}<i>2</i>{% endcontent_for %}\n"
    main = compile(app(LAYOUT, page), body: %(get "/" do\n  render :home, layout: :app\nend\n))
    assert_includes main, "<nav><i>1</i><i>2</i></nav>"
  end

  def test_a_partial_may_fill_a_region
    page = "{{ partial :crumb, label: \"Rooms\" }}<p>x</p>\n"
    crumb = "{% args label: %}{% content_for :nav %}<u>{{ label }}</u>{% endcontent_for %}\n"
    main = compile(app(LAYOUT, page, "crumb.html" => crumb), body: %(get "/" do\n  render :home, layout: :app\nend\n))
    assert_match(%r{<nav><u>.*Rooms.*</u></nav>}m, main)
  end

  def test_plain_yield_is_unchanged
    main = compile(app("<main>{{ yield }}</main>\n", "<p>hi</p>\n"), body: %(get "/" do\n  render :home, layout: :app\nend\n))
    assert_includes main, 'push_str("<main><p>hi</p>\n</main>\n")'
  end

  def test_the_locals_rule_counts_a_regions_markers
    msg = refusal(app("{{ yield :nav }}{{ yield }}\n", "{% content_for :nav %}{{ who }}{% endcontent_for %}x\n"))
    assert_includes msg, "views/home.html:1: `{{ who }}` reads a local, so the render must pass it"
  end

  # --- refusals ------------------------------------------------------------------------------------------

  PLAIN = %(get "/" do\n  render :home\nend\n)

  def test_yield_name_outside_a_layout
    assert_includes refusal({ "home.html" => "{{ yield :nav }}\n" }, body: PLAIN), "`{{ yield :nav }}` is a layout's region, and this render has no layout"
    assert_includes refusal(app(LAYOUT, "{{ yield :nav }}\n")), "writes a region, and a region is written by the layout"
    assert_includes refusal(app(LAYOUT, "{{ partial :p }}\n", "p.html" => "{{ yield :nav }}\n")), "a partial is inlined into its caller and has no regions"
  end

  def test_content_for_without_a_layout_or_a_matching_yield
    assert_includes refusal({ "home.html" => "{% content_for :nav %}x{% endcontent_for %}\n" }, body: PLAIN), "this render has no layout to put it in"
    page = "{% content_for :side %}x{% endcontent_for %}\n"
    msg = refusal(app("{{ yield :nav }}{{ yield }}\n", page))
    assert_includes msg, "views/home.html:1: `{% content_for :side %}` fills a region that views/app.html never writes"
    assert_includes msg, "writes `{{ yield :nav }}`"
    msg = refusal(app("{{ yield }}\n", page))
    assert_includes msg, "writes no region"
    msg = refusal(app("{{ yield }}\n", "{{ partial :p }}\n", "p.html" => page), body: ROUTE.sub(', locals: { title: "T" }', ""))
    assert_includes msg, "never writes"
  end

  def test_content_for_in_a_layout
    assert_includes refusal(app("{% content_for :nav %}x{% endcontent_for %}{{ yield }}\n", "p\n")), "is in a layout"
  end

  def test_content_for_nesting_and_inlining
    assert_includes refusal(app(LAYOUT, "{% content_for :a %}{% content_for :b %}x{% endcontent_for %}{% endcontent_for %}\n")),
                    "views/home.html:1: `{% content_for :b %}` cannot sit inside another `{% content_for %}`"
    assert_includes refusal(app(LAYOUT, "{% for n in ns %}{% content_for :a %}x{% endcontent_for %}{% endfor %}\n"),
                            body: %(get "/" do\n  render :home, layout: :app, locals: { ns: [1] }\nend\n)),
                    "cannot sit inside a `{% for %}`"
    assert_includes refusal(app(LAYOUT, "{% if show %}{% content_for :a %}x{% endcontent_for %}{% endif %}\n"),
                            body: %(get "/" do\n  render :home, layout: :app, locals: { show: true }\nend\n)),
                    "cannot sit inside a `{% if %}`"
    msg = refusal(app(LAYOUT, "{% if show %}{{ partial :p }}{% endif %}\n", "p.html" => "{% content_for :nav %}x{% endcontent_for %}\n"),
                  body: %(get "/" do\n  render :home, layout: :app, locals: { show: true }\nend\n))
    assert_includes msg, "is inlined inside a `{% for %}`, an `{% if %}` or another `{% content_for %}`"
  end

  def test_content_for_directive_shapes
    assert_includes refusal(app(LAYOUT, "{% content_for %}x{% endcontent_for %}\n")), "is not a region; a region is `{% content_for :nav %}`"
    assert_includes refusal(app(LAYOUT, "{% content_for nav %}x{% endcontent_for %}\n")), "named by a symbol"
    assert_includes refusal(app(LAYOUT, "{% content_for :nav %}x\n")), "views/home.html:1: this `{% content_for :nav %}` is never closed; a region ends with `{% endcontent_for %}`"
    assert_includes refusal(app(LAYOUT, "x\n{% endcontent_for %}\n")), "views/home.html:2: `{% endcontent_for %}` here has no `{% content_for %}` before it"
    assert_includes refusal(app(LAYOUT, "{% content_for :nav %}{% endif %}{% endcontent_for %}\n")), "has no `{% if %}` before it"
    assert_includes refusal(app(LAYOUT, "{% content_for :nav %}{% endfor %}{% endcontent_for %}\n")), "outside the open `{% content_for %}`"
    assert_includes refusal(app(LAYOUT, "{% content_for :nav %}{{ yield }}{% endcontent_for %}\n")), "cannot sit inside"
    assert_includes refusal(app(LAYOUT, "{% content_for :nav %}{{ yield :head }}{% endcontent_for %}\n")), "cannot sit inside"
  end

  def test_yield_name_marker_shapes
    assert_includes refusal(app("{{ yield nav }}{{ yield }}\n", "x\n")), "one of its named regions with `{{ yield :nav }}`"
    assert_includes refusal(app("{{ yield :nav|raw }}{{ yield }}\n", "x\n")), "a symbol with no filter"
    assert_includes refusal(app("{{ yield :nav, :x }}{{ yield }}\n", "x\n")), "is not a marker"
  end
end
