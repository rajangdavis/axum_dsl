# frozen_string_literal: true

# The view language's conditions, dotted reads of a record local and a page's defaults (docs/views.md, "Conditions",
# "A record's fields" and "Defaults for a page's locals"). Each case compiles a small DSL string beside its view and
# asserts on the emitted Rust, or on the refusal. No cargo and no HTTP.
#
#   ruby -Ilib test/test_view_conditions.rb
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "axum_dsl"

class TestViewConditions < Minitest::Test
  HEAD = <<~RB
    server "conds", version: "0.1.0"
    set :port, 8080
  RB

  PARAMS = <<~RB
    params :U do
      field :id, :i64
      field :name, :string
    end

    params :Q do
      field :count, :i64
      field :limit, :i64
      field :name, :string
      field :other, :string
      field :on, :bool
      field :off, :bool
      field :nick, :string, optional: true
      field :tags, list(:string)
      field :users, list(:U)
      field :ratio, :f64
    end
  RB

  DB = <<~RB
    database :sqlite, path: "x.db"

    record :Item do
      field :id, :i64
      field :name, :string
      field :status, :i64
      field :admin, :bool
      field :note, :string, optional: true

      def label = "#{name}!"
    end

    query :find_item, args: { id: :i64 }, returns: :Item?, sql: "SELECT id, name, status, admin, note FROM items WHERE id = :id"
  RB

  def compile(source, views)
    Dir.mktmpdir("conds") do |dir|
      views.each do |rel, text|
        FileUtils.mkdir_p(File.dirname(File.join(dir, "views", rel)))
        File.write(File.join(dir, "views", rel), text)
      end
      file = File.join(dir, "conds.axum.rb")
      File.write(file, HEAD + source)
      AxumDsl::Emit.files(AxumDsl.read(file), file)["src/main.rs"]
    end
  end

  # A post route over PARAMS that passes the named params to the view `home` as locals.
  def cond(view, names, partials: {})
    locals = names.map { |n| "#{n}: params[:#{n}]" }.join(", ")
    compile(PARAMS + %(post "/q", params: :Q do\n  render :home, locals: { #{locals} }\nend\n), { "home.html" => view }.merge(partials))
  end

  def refused(view, names, partials: {})
    assert_raises(AxumDsl::CompileError) { cond(view, names, partials: partials) }.message
  end

  # ---- V1: conditions ----

  def test_a_name_is_compared_with_a_literal
    assert_includes cond(%({% if name == "bob" %}x{% endif %}\n), %w[name]), 'if name.as_str() == "bob" {'
    assert_includes cond(%({% if name != "bob" %}x{% endif %}\n), %w[name]), 'if name.as_str() != "bob" {'
    assert_match(/\bif count == 3 \{/, cond("{% if count == 3 %}x{% endif %}\n", %w[count]))
    assert_match(/\bif count != 3 \{/, cond("{% if count != 3 %}x{% endif %}\n", %w[count]))
    assert_match(/\bif on == true \{/, cond("{% if on == true %}x{% endif %}\n", %w[on]))
  end

  def test_two_names_are_compared_with_not_equal
    assert_match(/\bif count != limit \{/, cond("{% if count != limit %}x{% endif %}\n", %w[count limit]))
    assert_includes cond("{% if name != other %}x{% endif %}\n", %w[name other]), "name.as_str() != other.as_str()"
  end

  def test_an_equality_of_two_names_is_still_the_old_condition
    assert_match(/\bif count == limit \{/, cond("{% if count == limit %}x{% endif %}\n", %w[count limit]))
  end

  def test_integers_are_ordered
    assert_match(/\bif count > 20 \{/, cond("{% if count > 20 %}x{% endif %}\n", %w[count]))
    assert_match(/\bif count >= limit \{/, cond("{% if count >= limit %}x{% endif %}\n", %w[count limit]))
    assert_match(/\bif 3 < count \{/, cond("{% if 3 < count %}x{% endif %}\n", %w[count]))
    assert_match(/\bif count <= -1 \{/, cond("{% if count <= -1 %}x{% endif %}\n", %w[count]))
  end

  def test_not_negates_a_bool_and_a_nil_able
    assert_match(/\bif !on \{/, cond("{% if !on %}x{% endif %}\n", %w[on]))
    assert_includes cond("{% if !nick %}x{% endif %}\n", %w[nick]), "if !nick.is_some() {"
  end

  def test_terms_join_with_and_or_left_to_right
    assert_match(/\bif count > 20 && on \{/, cond("{% if count > 20 && on %}x{% endif %}\n", %w[count on]))
    assert_match(/\bif on \|\| !off \|\| name.as_str\(\) == "x" \{/, cond(%({% if on || !off || name == "x" %}x{% endif %}\n), %w[on off name]))
  end

  def test_empty_any_length_and_size
    assert_includes cond("{% if name.empty? %}x{% endif %}\n", %w[name]), "if name.is_empty() {"
    assert_includes cond("{% if !name.empty? %}x{% endif %}\n", %w[name]), "if !name.is_empty() {"
    assert_includes cond("{% if tags.empty? %}x{% endif %}\n", %w[tags]), "if tags.is_empty() {"
    assert_includes cond("{% if tags.any? %}x{% endif %}\n", %w[tags]), "if !tags.is_empty() {"
    assert_includes cond("{% if tags.length > 20 %}x{% endif %}\n", %w[tags]), "if (tags.len() as i64) > 20 {"
    assert_includes cond("{% if name.size >= 3 %}x{% endif %}\n", %w[name]), "if (name.chars().count() as i64) >= 3 {"
  end

  def test_conditions_read_a_loop_variable_and_its_fields
    main = cond("{% for u in users %}{% if u.id > 1 && u.name != \"x\" %}{{ u.name }}{% endif %}{% if u.name.empty? %}-{% endif %}{% endfor %}\n", %w[users])
    assert_includes main, 'if __it_u.id > 1 && __it_u.name.as_str() != "x" {'
    assert_includes main, "if __it_u.name.is_empty() {"
    main = cond("{% for t in tags %}{% if t == \"a\" || t.length > 2 %}{{ t }}{% endif %}{% endfor %}\n", %w[tags])
    assert_includes main, 'if __it_t.as_str() == "a" || (__it_t.as_str().chars().count() as i64) > 2 {'
  end

  def test_a_nil_able_name_still_narrows_in_its_if
    main = cond("{% if nick %}{{ nick }}{% endif %}\n", %w[nick])
    assert_includes main, "if let Some(__if_nick) = nick.as_deref() {"
  end

  def test_the_condition_reads_count_as_locals
    msg = refused("{% if count > 20 %}x{% endif %}\n", %w[count limit])
    assert_includes msg, "`limit` is passed to this render but no marker reads it"
    msg = refused("{% if count > limit %}x{% endif %}\n", %w[count])
    assert_includes msg, "`{% if limit %}` reads a local"
  end

  def test_a_condition_with_parentheses_is_refused
    msg = refused("{% if (on && off) || name.empty? %}x{% endif %}\n", %w[on off name])
    assert_includes msg, "has parentheses"
    assert_includes msg, "left to right"
  end

  def test_mixed_and_or_is_refused
    msg = refused("{% if on && off || name.empty? %}x{% endif %}\n", %w[on off name])
    assert_includes msg, "mixes `&&` and `||`"
  end

  def test_a_string_is_not_compared_with_an_integer
    msg = refused("{% if name == 3 %}x{% endif %}\n", %w[name])
    assert_includes msg, "`name` (String)"
    assert_includes msg, "the integer 3"
    assert_includes msg, "is compared with a string"
  end

  def test_an_integer_is_not_compared_with_a_string
    msg = refused(%({% if count == "3" %}x{% endif %}\n), %w[count])
    assert_includes msg, "`count` (Integer (i64))"
    assert_includes msg, "is compared with an integer"
  end

  def test_only_integers_are_ordered
    msg = refused(%({% if name < "b" %}x{% endif %}\n), %w[name])
    assert_includes msg, "`<` orders integers"
    assert_includes msg, "`name` is String"
  end

  def test_a_float_is_not_compared
    assert_includes refused("{% if ratio == 1 %}x{% endif %}\n", %w[ratio]), "Float"
  end

  def test_an_integer_is_not_a_condition_term
    msg = refused("{% if count && on %}x{% endif %}\n", %w[count on])
    assert_includes msg, "tests `count`"
    assert_includes msg, "a condition is a `bool` or a nil-able value"
  end

  def test_a_nil_able_is_not_compared
    msg = refused(%({% if nick == "a" %}x{% endif %}\n), %w[nick])
    assert_includes msg, "`nick`"
    assert_includes msg, "may be nil"
  end

  def test_methods_are_checked_against_the_type
    assert_includes refused("{% if count.empty? %}x{% endif %}\n", %w[count]), "is for a string or a list"
    assert_includes refused("{% if name.any? %}x{% endif %}\n", %w[name]), "`.any?` is for a list"
    assert_includes refused("{% if nick.empty? %}x{% endif %}\n", %w[nick]), "may be nil"
  end

  def test_not_before_a_comparison_and_two_comparisons_are_refused
    assert_includes refused("{% if !count > 3 %}x{% endif %}\n", %w[count]), "cannot be put before a comparison"
    assert_includes refused("{% if count > 3 > 2 %}x{% endif %}\n", %w[count]), "more than one comparison"
  end

  def test_a_malformed_condition_is_refused_with_what_is_allowed
    msg = refused("{% if count + 1 %}x{% endif %}\n", %w[count])
    assert_includes msg, "is not a condition"
    assert_includes msg, "`name.empty?`"
    assert_includes refused("{% if count > %}x{% endif %}\n", %w[count]), "is not a condition"
    assert_includes refused("{% if && on %}x{% endif %}\n", %w[on]), "a term is empty"
  end

  # ---- V2: dotted reads on a record local ----

  def record_route(view, extra: "", route: nil)
    route ||= %(get "/" do\n  page = find_item(id: 1)\n  render :home, locals: { page: page }\nend\n)
    compile(DB + extra + route, { "home.html" => view })
  end

  def narrowed(inner)
    "{% if page %}#{inner}{% endif %}\n"
  end

  def test_a_narrowed_record_local_is_read_field_by_field
    main = record_route(narrowed("<b>{{ page.name }}</b>{% if page.admin %}!{% endif %}{% if page.status == 2 %}banned{% endif %}"))
    assert_includes main, "if let Some(__if_page) = page.as_ref() {"
    assert_includes main, "__if_page.name"
    assert_includes main, "if __if_page.admin {"
    assert_includes main, "if __if_page.status == 2 {"
  end

  def test_a_record_method_is_read_like_a_field
    main = record_route(narrowed("{{ page.label }}"))
    assert_includes main, "__if_page.label()"
  end

  def test_a_nil_able_field_narrows_under_its_key
    main = record_route(narrowed("{% if page.note %}{{ page.note }}{% endif %}"))
    assert_includes main, "if let Some(__if_page_note) = __if_page.note.as_deref() {"
  end

  def test_a_record_field_goes_to_a_partial_and_a_condition_with_length
    dsl = DB + %(get "/" do\n  page = find_item(id: 1)\n  render :home, locals: { page: page }\nend\n)
    main = compile(dsl, { "home.html" => narrowed(%({{ partial :row, who: page.name }}{% if page.name.empty? %}-{% endif %}{% if page.name.length > 3 %}+{% endif %})),
                          "row.html" => "<i>{{ who }}</i>" })
    assert_includes main, "__if_page.name"
    assert_includes main, "if __if_page.name.is_empty() {"
    assert_includes main, "(__if_page.name.chars().count() as i64) > 3"
  end

  def test_a_record_local_with_no_field_read_is_a_local_no_marker_reads
    msg = assert_raises(AxumDsl::CompileError) { record_route("<p>hi</p>\n") }.message
    assert_includes msg, "`page` is passed to this render but no marker reads it"
  end

  def test_an_unknown_field_is_refused_with_a_did_you_mean
    msg = assert_raises(AxumDsl::CompileError) { record_route(narrowed("{{ page.nme }}")) }.message
    assert_includes msg, "Item has no field `nme`"
    assert_includes msg, "did you mean `name`?"
  end

  def test_a_nil_able_record_is_read_inside_its_if
    msg = assert_raises(AxumDsl::CompileError) { record_route("{{ page.name }}\n") }.message
    assert_includes msg, "`page.name` reads a field of `page`"
    assert_includes msg, "read it inside `{% if page %}`"
  end

  def test_a_dotted_read_of_a_scalar_local_is_refused
    msg = refused("{{ name.size }}\n", %w[name])
    assert_includes msg, "`name` is String, which has no fields"
  end

  def test_a_record_field_that_may_be_nil_is_not_written
    msg = assert_raises(AxumDsl::CompileError) { record_route(narrowed("{{ page.note }}")) }.message
    assert_includes msg, "`page.note` is optional and may be nil"
  end

  # ---- V3: defaults for a page's locals ----

  def defaults(view, locals: "", route_body: nil)
    compile(PARAMS + %(post "/q", params: :Q do\n  render :home#{locals.empty? ? '' : ", locals: { #{locals} }"}\nend\n), { "home.html" => view })
  end

  def test_a_page_local_with_a_default_may_be_omitted
    main = defaults(%({% args title:, hint: "none", n: 3, on: false %}{{ title }}{{ hint }}{{ n }}{% if on %}!{% endif %}\n),
                    locals: "title: params[:name]")
    assert_includes main, 'none3' # the defaults are literals, written as text beside each other
    assert_includes main, "if false {"
  end

  def test_a_given_value_replaces_the_default
    main = defaults(%({% args hint: "none" %}{{ hint }}\n), locals: "hint: params[:name]")
    refute_includes main, '"none"'
  end

  def test_a_local_without_a_default_stays_required
    msg = assert_raises(AxumDsl::CompileError) { defaults(%({% args title:, hint: "" %}{{ title }}{{ hint }}\n)) }.message
    assert_includes msg, "`{{ title }}` reads a local, so the render must pass it"
  end

  def test_a_default_must_match_the_type_the_render_passes
    msg = assert_raises(AxumDsl::CompileError) { defaults(%({% args n: "x" %}{{ n }}\n), locals: "n: params[:count]") }.message
    assert_includes msg, "the default of `n:`"
    assert_includes msg, "String"
    assert_includes msg, "Integer (i64)"
  end

  def test_a_default_that_the_view_uses_wrongly_is_refused
    msg = assert_raises(AxumDsl::CompileError) { defaults(%({% args items: "" %}{% for i in items %}{{ i }}{% endfor %}\n)) }.message
    assert_includes msg, "`items`"
    assert_includes msg, "not a list"
  end

  def test_args_must_list_the_names_the_page_reads
    msg = assert_raises(AxumDsl::CompileError) { defaults(%({% args hint: "" %}{{ hint }}{{ title }}\n), locals: "title: params[:name]") }.message
    assert_includes msg, "`title` is read here but `{% args %}`"
  end

  def test_a_layout_still_takes_no_args
    Dir.mktmpdir("conds") do |dir|
      FileUtils.mkdir_p(File.join(dir, "views"))
      File.write(File.join(dir, "views", "home.html"), "<p>hi</p>\n")
      File.write(File.join(dir, "views", "app.html"), "{% args %}<main>{{ yield }}</main>\n")
      file = File.join(dir, "conds.axum.rb")
      File.write(file, HEAD + %(get "/" do\n  render :home, layout: :app\nend\n))
      msg = assert_raises(AxumDsl::CompileError) { AxumDsl::Emit.files(AxumDsl.read(file), file) }.message
      assert_includes msg, "this file is a layout"
    end
  end
end
