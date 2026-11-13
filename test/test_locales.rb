# frozen_string_literal: true

# Locales (`t`, `{{ t }}`, config/locales/*.yml, `default_locale`): each case compiles a small DSL string beside its
# locale files and views in a temp folder and asserts on the emitted Rust, or on the refusal. No cargo, no HTTP.
# Locales are opt-in, so the first cases pin that a file with no `t` emits exactly what it always did.
#
#   ruby -Ilib test/test_locales.rb
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "axum_dsl"

class TestLocales < Minitest::Test
  HEAD = <<~RB
    server "loc", version: "0.1.0"
    set :port, 8080
  RB

  EN = <<~YML
    en:
      greeting: "Hello, %{name}!"
      title: "Chat bots"
      only_en: "English only"
      bots:
        index:
          title: "Bots"
  YML

  ES = <<~YML
    es:
      greeting: "Hola, %{name}!"
      title: "Bots de chat"
      bots:
        index:
          title: "Los bots"
  YML

  FILES = { "en.yml" => EN, "es.yml" => ES }.freeze

  def compile(source, files: FILES, views: {}, head: HEAD)
    Dir.mktmpdir("loc") do |dir|
      files.each do |name, text|
        FileUtils.mkdir_p(File.join(dir, "config/locales"))
        File.write(File.join(dir, "config/locales", name), text)
      end
      views.each do |rel, text|
        FileUtils.mkdir_p(File.dirname(File.join(dir, "views", rel)))
        File.write(File.join(dir, "views", rel), text)
      end
      file = File.join(dir, "loc.axum.rb")
      File.write(file, head + source)
      AxumDsl::Emit.files(AxumDsl.read(file), file)["src/main.rs"]
    end
  end

  def refusal(source, **opts)
    assert_raises(AxumDsl::CompileError) { compile(source, **opts) }.message
  end

  ROUTE = %(get "/" do\n  text("hi")\nend\n)

  def test_a_file_that_never_calls_t_emits_nothing_of_locales
    main = compile(ROUTE, files: {})
    %w[axum_dsl_locale __locale RawQuery axum_dsl_t_].each { |s| refute_includes main, s }
  end

  def test_locale_files_beside_a_file_that_never_calls_t_change_nothing
    assert_equal compile(ROUTE, files: {}), compile(ROUTE)
    assert_equal compile(ROUTE, files: {}), compile("default_locale :es\n#{ROUTE}")
  end

  def test_t_with_no_locale_files_says_where_to_add_one
    msg = refusal(%(get "/" do\n  text(t("title"))\nend\n), files: {})
    assert_includes msg, "`t` needs locale files"
    assert_includes msg, "config/locales/en.yml"
  end

  def test_a_literal_string_stays_legal_next_to_t
    main = compile(%(get "/" do\n  text("literal \#{t("title")}")\nend\n))
    assert_includes main, "literal"
    assert_includes main, "axum_dsl_t_0(__locale)"
  end

  def test_t_in_a_route_looks_the_key_up_by_locale
    main = compile(%(get "/" do\n  text(t("title"))\nend\n))
    assert_includes main, "fn axum_dsl_t_0(__locale: &str) -> String {"
    assert_includes main, %("es" => "Bots de chat".to_string(),)
    assert_includes main, %(_ => "Chat bots".to_string(),)
  end

  def test_nested_keys_are_dotted
    main = compile(%(get "/" do\n  text(t("bots.index.title"))\nend\n))
    assert_includes main, %(_ => "Bots".to_string(),)
    assert_includes main, %("es" => "Los bots".to_string(),)
  end

  def test_the_locale_comes_from_the_query_parameter_else_the_default
    main = compile(%(get "/" do\n  text(t("title"))\nend\n))
    assert_includes main, "::axum::extract::RawQuery(__raw_query): ::axum::extract::RawQuery"
    assert_includes main, "let __locale = axum_dsl_locale(__raw_query.as_deref());"
    assert_includes main, %(pair.strip_prefix("locale="))
    assert_includes main, %("es" => return "es",)
    assert_includes main, %(    "en"\n}) # the default, when no parameter names a locale a file holds
  end

  def test_default_locale_names_the_fallback_locale
    main = compile("default_locale :es\n" + %(get "/" do\n  text(t("title"))\nend\n))
    assert_includes main, %(    "es"\n}) # the picker's last line
    assert_includes main, %(_ => "Bots de chat".to_string(),)
  end

  def test_default_locale_that_no_file_holds_is_refused
    msg = refusal("default_locale :fr\n" + %(get "/" do\n  text(t("title"))\nend\n))
    assert_includes msg, "`default_locale :fr` names a locale no file in config/locales/ holds"
  end

  def test_interpolation_fills_the_named_arguments
    main = compile(%(get "/" do\n  who = "Ada"\n  text(t("greeting", name: who))\nend\n))
    assert_includes main, "fn axum_dsl_t_0(__locale: &str, p_name: &str) -> String {"
    assert_includes main, %(_ => ["Hello, ", p_name, "!"].concat(),)
    assert_includes main, %("es" => ["Hola, ", p_name, "!"].concat(),)
  end

  def test_a_missing_interpolation_argument_is_refused
    msg = refusal(%(get "/" do\n  text(t("greeting"))\nend\n))
    assert_includes msg, "missing the interpolation argument `name:`"
  end

  def test_an_extra_interpolation_argument_is_refused
    msg = refusal(%(get "/" do\n  text(t("title", name: "x"))\nend\n))
    assert_includes msg, "passes `name:`, but the text"
  end

  def test_a_locale_whose_text_interpolates_other_names_is_refused
    es = "es:\n  greeting: \"Hola, %{nombre}!\"\n"
    msg = refusal(%(get "/" do\n  text(t("greeting", name: "x"))\nend\n), files: { "en.yml" => EN, "es.yml" => es })
    assert_includes msg, "the es text in config/locales/es.yml"
  end

  def test_a_key_missing_from_the_default_locale_is_refused_at_the_call_with_a_suggestion
    msg = refusal(%(get "/" do\n  text(t("titel"))\nend\n))
    assert_match(/loc\.axum\.rb:\d+/, msg)
    assert_includes msg, "the key `titel` is missing from the default locale `en` (config/locales/en.yml)"
    assert_includes msg, "did you mean `title`?"
  end

  def test_a_key_missing_from_another_locale_falls_back_to_the_default_text
    main = compile(%(get "/" do\n  text(t("only_en"))\nend\n))
    assert_includes main, %(fn axum_dsl_t_0(__locale: &str) -> String {\n    match __locale {\n        _ => "English only".to_string(),\n    }\n})
  end

  def test_a_lazy_key_in_a_route_is_refused
    msg = refusal(%(get "/" do\n  text(t(".title"))\nend\n))
    assert_includes msg, "the lazy form, which resolves against the view"
  end

  def test_t_outside_a_request_body_is_refused
    msg = refusal(%(current :who, returns: :string do\n  t("title")\nend\nget "/" do\n  text(current(:who))\nend\n))
    assert_includes msg, "`t` reads the request's locale"
  end

  def test_a_view_marker_resolves_the_lazy_key_against_its_path_and_escapes
    main = compile(%(get "/" do\n  render "bots/index", layout: nil, locals: { who: "Ada" }\nend\n),
                   views: { "bots/index.html" => %(<h1>{{ t ".title" }}</h1><p>{{ t "greeting", name: who }}</p>\n) })
    assert_includes main, %(_ => "Bots".to_string(),) # bots.index.title
    assert_includes main, "axum_dsl_html_escape_into(&mut __out, &axum_dsl_t_0(__locale));"
    assert_includes main, "axum_dsl_html_escape_into(&mut __out, &axum_dsl_t_1(__locale, "
  end

  def test_a_partial_is_scoped_by_its_own_path
    views = { "home.html" => %({{ partial :form_field }}\n), "form_field.html" => %(<b>{{ t ".title" }}</b>\n) }
    msg = refusal(%(get "/" do\n  render :home, layout: nil\nend\n), views: views)
    assert_includes msg, "views/form_field.html:1:"
    assert_includes msg, "the key `form_field.title` is missing"
  end

  def test_a_view_marker_refuses_a_missing_key_at_the_views_own_line
    msg = refusal(%(get "/" do\n  render :home, layout: nil\nend\n), views: { "home.html" => %(<p>x</p>\n<p>{{ t ".nope" }}</p>\n) })
    assert_includes msg, "views/home.html:2:"
    assert_includes msg, "the key `home.nope` is missing from the default locale `en`"
  end

  def test_a_view_marker_checks_its_interpolation
    msg = refusal(%(get "/" do\n  render :home, layout: nil\nend\n), views: { "home.html" => %(<p>{{ t "greeting" }}</p>\n) })
    assert_includes msg, "views/home.html:1:"
    assert_includes msg, "missing the interpolation argument `name:`"
  end

  def test_a_local_named_t_is_still_a_marker
    main = compile(%(get "/" do\n  render :home, layout: nil, locals: { t: "x" }\nend\n), files: {}, views: { "home.html" => "<p>{{ t }}</p>\n" })
    refute_includes main, "axum_dsl_locale"
  end
end
