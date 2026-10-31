# frozen_string_literal: true

# Declared sanitizers: `sanitizer :name, tags: [...], attributes: [...]` and a view's `{{ body|sanitize :name }}`,
# plus `{% if body|all_emoji %}` (docs/views.md, "Declared sanitizers"). Each case compiles a small DSL string beside
# its view files and asserts on the emitted Rust, or on the refusal. No cargo and no HTTP.
#
#   ruby -Ilib test/test_sanitizer.rb
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "axum_dsl"

class TestSanitizer < Minitest::Test
  HEAD = <<~RB
    server "sanitizer", version: "0.1.0"
    set :port, 8080
  RB

  SANITIZER = <<~RB
    sanitizer :message_body, tags: %w[p a table], attributes: %w[href class], link_rel: false, autolink_target: "_blank"
  RB

  ROUTE = %(get "/" do\n  render :home, locals: { body: "<p>x</p>" }\nend\n)

  def compile(view, dsl: SANITIZER + ROUTE)
    Dir.mktmpdir("sanitizer") do |dir|
      FileUtils.mkdir_p(File.join(dir, "views"))
      File.write(File.join(dir, "views", "home.html"), view)
      file = File.join(dir, "sanitizer.axum.rb")
      File.write(file, HEAD + dsl)
      AxumDsl::Emit.files(AxumDsl.read(file), file)
    end
  end

  def refusal(view, dsl)
    assert_raises(AxumDsl::CompileError) { compile(view, dsl: dsl) }.message
  end

  def test_a_declared_sanitizer_is_built_from_exactly_its_lists
    files = compile("<div>{{ body|sanitize :message_body }}</div>\n")
    main = files["src/main.rs"]
    assert_includes main, 'AxumDslSanitizer::new(&["p", "a", "table"], &["href", "class"], false, Some("_blank"))'
    assert_includes main, "axum_dsl_sanitize_message_body_into(&mut __out,"
    refute_includes main, "static AXUM_DSL_SANITIZER:", "the default sanitiser is not emitted for a file that only names profiles"
    assert_includes files["Cargo.toml"], 'ammonia = "4"'
  end

  def test_the_default_filter_and_a_profile_can_share_a_file
    main = compile("{{ body|sanitize }}{{ body|sanitize :message_body }}\n")["src/main.rs"]
    assert_includes main, "fn axum_dsl_sanitize_into("
    assert_includes main, "fn axum_dsl_sanitize_message_body_into("
  end

  def test_link_rel_is_kept_unless_the_declaration_turns_it_off
    dsl = %(sanitizer :plain, tags: %w[p a], attributes: %w[href]\n) + ROUTE
    main = compile("{{ body|sanitize :plain }}\n", dsl: dsl)["src/main.rs"]
    assert_includes main, 'AxumDslSanitizer::new(&["p", "a"], &["href"], true, None)'
  end

  def test_all_emoji_emits_the_predicate_and_the_regex_dependency
    files = compile("<div class=\"m {% if body|all_emoji %}emoji{% endif %}\">{{ body|sanitize :message_body }}</div>\n")
    assert_includes files["src/main.rs"], "fn axum_dsl_all_emoji("
    assert_includes files["src/main.rs"], "if axum_dsl_all_emoji("
    assert_includes files["Cargo.toml"], 'regex = "1"'
  end

  def test_an_unknown_profile_is_refused_with_what_is_declared
    msg = refusal("{{ body|sanitize :nope }}\n", ROUTE)
    assert_includes msg, "names no `sanitizer :nope`"
    assert_includes msg, "the file declares no sanitizer"
  end

  def test_an_unused_sanitizer_is_refused
    assert_includes refusal("{{ body }}\n", SANITIZER + ROUTE), "no view names it"
  end

  def test_a_tag_that_runs_script_is_refused
    dsl = %(sanitizer :bad, tags: %w[p script], attributes: %w[href]\n) + ROUTE
    assert_includes refusal("{{ body|sanitize :bad }}\n", dsl), "may not allow the tag `script`"
  end

  def test_an_event_handler_attribute_is_refused
    dsl = %(sanitizer :bad, tags: %w[p], attributes: %w[onclick]\n) + ROUTE
    assert_includes refusal("{{ body|sanitize :bad }}\n", dsl), "may not allow the attribute `onclick`"
  end

  def test_all_emoji_needs_a_string
    dsl = SANITIZER + %(get "/" do\n  render :home, locals: { body: 3 }\nend\n)
    assert_includes refusal("{% if body|all_emoji %}x{% endif %}\n", dsl), "needs an HTML string"
  end

  # --- attachments: and sounds: (a body's <action-text-attachment> and `/play NAME`) ---

  SITE_HEAD = <<~RB
    static "/assets", dir: "public", digest: true
  RB

  EMBED_PARTIAL = <<~HTML
    <div class="og">{% if has_href %}<a href="{{ href }}">{{ title }}</a>{% endif %}{{ description }}{% if twitter_avatar %}t{% endif %}{% if has_image %}<img src="{{ image }}">{% endif %}</div>
  HTML

  SOUND_FILES = { "public/bell.mp3" => "bell", "public/56k.mp3" => "56k", "public/sounds/56k.webp" => "img" }.freeze

  DRAWING = <<~RB
    sanitizer :message_body, tags: %w[p a div img], attributes: %w[href src class],
              attachments: { "application/vnd.actiontext.opengraph-embed" => :og },
              sound_partials: { text: :snd_text, image: :snd_image },
              sounds: { "bell" => "🔔", "56k" => ["sounds/56k.webp", 79, 33] }
  RB

  def compile_site(view, dsl: SITE_HEAD + DRAWING + ROUTE, views: {}, files: SOUND_FILES)
    Dir.mktmpdir("sanitizer") do |dir|
      FileUtils.mkdir_p(File.join(dir, "views"))
      File.write(File.join(dir, "views", "home.html"), view)
      { "og" => EMBED_PARTIAL, "snd_text" => "<b>{{ url }}{{ text }}</b>", "snd_image" => "<i>{{ url }}{{ src }}{{ width }}{{ height }}</i>" }.merge(views).each do |name, text|
        File.write(File.join(dir, "views", "#{name}.html"), text)
      end
      files.each do |path, text|
        FileUtils.mkdir_p(File.dirname(File.join(dir, path)))
        File.write(File.join(dir, path), text)
      end
      file = File.join(dir, "sanitizer.axum.rb")
      File.write(file, HEAD + dsl)
      AxumDsl::Emit.files(AxumDsl.read(file), file)
    end
  end

  # ActionText::ContentHelper#render_action_text_attachment chomps the partial it renders.
  def test_a_drawn_attachment_is_chomped
    main = compile_site(VIEW, dsl: SITE_HEAD + DRAWING + ROUTE_HOST)["src/main.rs"]
    assert_includes main, "drawn.ends_with('\\n')"
  end

  def site_refusal(view, dsl: SITE_HEAD + DRAWING + ROUTE, **opts)
    assert_raises(AxumDsl::CompileError) { compile_site(view, dsl: dsl, **opts) }.message
  end

  VIEW = "{% if body|sound :message_body %}S{% endif %}{{ body|sanitize :message_body, host: base }}\n"
  ROUTE_HOST = %(get "/" do\n  render :home, locals: { body: "<p>x</p>", base: "http://a.test" }\nend\n)

  def test_attachment_and_sound_partials_compile_to_functions_the_sanitizer_calls
    files = compile_site(VIEW, dsl: SITE_HEAD + DRAWING + ROUTE_HOST)
    main = files["src/main.rs"]
    assert_includes main, "fn axum_dsl_render_message_body_og(_href: &str, _title: &str, _description: &str, _image: &str, _twitter_avatar: bool, _has_href: bool, _has_image: bool) -> String"
    assert_includes main, "fn axum_dsl_render_message_body_snd_text(_url: &str, _text: &str) -> String"
    assert_includes main, "fn axum_dsl_render_message_body_snd_image(_url: &str, _src: &str, _width: &str, _height: &str) -> String"
    assert_match %r{"bell" => Some\(axum_dsl_render_message_body_snd_text\("/assets/bell-[0-9a-f]{8}\.mp3", "🔔"\)\)}, main
    assert_match %r{"56k" => Some\(axum_dsl_render_message_body_snd_image\("/assets/56k-[0-9a-f]{8}\.mp3", "/assets/sounds/56k-[0-9a-f]{8}\.webp", "79", "33"\)\)}, main
    assert_includes main, ".with_attachments(axum_dsl_attachments_message_body).with_sounds(axum_dsl_sounds_message_body)"
    assert_includes main, "fn axum_dsl_sanitize_message_body_into(buf: &mut String, html: &str, host: &str)"
    assert_includes main, "if axum_dsl_is_sound_message_body("
    assert_includes main, "axum_dsl_sanitize_message_body_into(&mut __out, "
    assert_includes files["Cargo.toml"], 'scraper = "0.20"'
  end

  def test_a_sanitizer_without_attachments_or_sounds_emits_neither_runtime
    main = compile("{{ body|sanitize :message_body }}\n")["src/main.rs"]
    refute_includes main, "axum_dsl_draw_embeds"
    refute_includes main, "axum_dsl_play_name"
    refute_includes compile("{{ body|sanitize :message_body }}\n")["Cargo.toml"], "scraper"
  end

  def test_a_sanitizer_that_draws_attachments_needs_the_request_host
    msg = site_refusal("{{ body|sanitize :message_body }}\n", dsl: SITE_HEAD + DRAWING + ROUTE)
    assert_includes msg, "renders attachments"
    assert_includes msg, "host: base_url"
  end

  def test_host_is_for_a_sanitizer_that_draws_attachments
    dsl = SITE_HEAD + SANITIZER + %(get "/" do\n  render :home, locals: { body: "x", base: "y" }\nend\n)
    assert_includes site_refusal("{{ body|sanitize :message_body, host: base }}\n", dsl: dsl), "`host:` is for a sanitizer that renders `attachments:`"
  end

  def test_the_sound_test_needs_a_sanitizer_that_lists_sounds
    dsl = SITE_HEAD + SANITIZER + ROUTE
    assert_includes site_refusal("{% if body|sound :message_body %}x{% endif %}{{ body|sanitize :message_body }}\n", dsl: dsl), "needs sanitizer `message_body` to declare `sounds:`"
  end

  def test_an_attachment_type_the_compiler_cannot_read_is_refused
    dsl = SITE_HEAD + %(sanitizer :b, tags: %w[p], attributes: %w[class], attachments: { "image/png" => :og }\n) + ROUTE
    assert_includes site_refusal("{{ body|sanitize :b, host: x }}\n", dsl: dsl), "cannot render the attachment type \"image/png\""
  end

  def test_sounds_need_their_partials
    dsl = SITE_HEAD + %(sanitizer :b, tags: %w[p], attributes: %w[class], sounds: { "bell" => "x" }\n) + ROUTE
    assert_includes site_refusal("{{ body|sanitize :b }}\n", dsl: dsl), "needs `sound_partials:"
  end

  def test_a_sound_is_text_or_an_image_list
    dsl = SITE_HEAD + %(sanitizer :b, tags: %w[p], attributes: %w[class], sound_partials: { text: :a, image: :b }, sounds: { "bell" => 3 }\n) + ROUTE
    assert_includes site_refusal("{{ body|sanitize :b }}\n", dsl: dsl), "is its text"
  end

  def test_a_partial_must_read_exactly_the_arguments_the_compiler_gives_it
    msg = site_refusal(VIEW, dsl: SITE_HEAD + DRAWING + ROUTE_HOST, views: { "snd_text" => "{{ url }}{{ colour }}" })
    assert_includes msg, "sanitizer partial :snd_text"
    assert_includes msg, "colour"
  end

  def test_a_sound_file_that_is_not_in_the_mount_is_refused
    msg = site_refusal(VIEW, dsl: SITE_HEAD + DRAWING + ROUTE_HOST, files: SOUND_FILES.reject { |path, _| path == "public/bell.mp3" })
    assert_includes msg, '"bell.mp3", which is no file under the "/assets" mount'
  end

  # --- `{{ body|editable :profile }}`: the value Rails gives <lexxy-editor> (RichTextHelper#editable_body, then Lexxy's
  # render_custom_attachments_in). The expected output is once-campfire-rust's recorded Rails output (tests/corpus, case
  # "lexxy mention": content="&quot;\u003cspan class=\&quot;mention\&quot; sgid=...", and reference_tests.rs
  # editable_body_*). These cases check what the compiler writes; the running service answers it in
  # campfire_axum_dsl (state interactions/edit_form/with_mention).

  MENTION = "application/vnd.campfire.mention"
  OPENGRAPH = "application/vnd.actiontext.opengraph-embed"

  EDITABLE_DSL = <<~RB
    database :sqlite, path: "t.sqlite3", env: "DATABASE_PATH"
    migrations "db"
    record :Mentioned do
      field :id, :i64
      field :name, :string
      field :title, :string
      field :version, :string
    end
    query :mentioned, args: {}, returns: list(:Mentioned), sql: "SELECT id, name, title, version FROM users"
    sanitizer :message_body, tags: %w[p a div img], attributes: %w[href src class],
              attachments: { "#{OPENGRAPH}" => :og, "#{MENTION}" => :mention }
    get "/" do
      render :home, locals: { body: "<p>x</p>", base: "http://a.test", users: mentioned() }
    end
  RB

  def compile_editable(view, dsl: EDITABLE_DSL)
    Dir.mktmpdir("sanitizer") do |dir|
      FileUtils.mkdir_p(File.join(dir, "views"))
      FileUtils.mkdir_p(File.join(dir, "db"))
      File.write(File.join(dir, "db", "001_create_users.sql"), "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, title TEXT NOT NULL, version TEXT NOT NULL);\n")
      File.write(File.join(dir, "views", "home.html"), view)
      File.write(File.join(dir, "views", "og.html"), EMBED_PARTIAL)
      File.write(File.join(dir, "views", "mention.html"), "<b>{{ id }}{{ name }}{{ title }}{{ version }}</b>\n")
      file = File.join(dir, "sanitizer.axum.rb")
      File.write(file, HEAD + dsl)
      AxumDsl::Emit.files(AxumDsl.read(file), file)
    end
  end

  def editable_refusal(view, dsl: EDITABLE_DSL)
    assert_raises(AxumDsl::CompileError) { compile_editable(view, dsl: dsl) }.message
  end

  EDITABLE_VIEW = "<lexxy-editor name=\"message[body]\" {{ body|editable :message_body, host: base, mentions: users }}></lexxy-editor>\n"

  def test_editable_calls_a_function_over_the_sanitizers_partials
    main = compile_editable(EDITABLE_VIEW)["src/main.rs"]
    assert_includes main, "fn axum_dsl_editable_message_body_into(buf: &mut String, html: &str, host: &str, mentions: &[AxumDslMention])"
    assert_includes main, "axum_dsl_editable_attribute(buf, html, host, axum_dsl_render_message_body_og, axum_dsl_render_message_body_mention, mentions);"
    assert_includes main, "axum_dsl_editable_message_body_into(&mut __out, "
  end

  # Rails' two passes: the attachable's content type and chomped partial, then Lexxy's JSON string for an attachment
  # with no url, whose `<`, `>` and `&` are the \u escapes ActiveSupport writes.
  def test_editable_writes_both_of_rails_passes
    main = compile_editable(EDITABLE_VIEW)["src/main.rs"]
    assert_includes main, 'axum_dsl_editable_set(attrs, "content-type", content_type.to_string());'
    assert_includes main, 'axum_dsl_editable_set(attrs, "content", content);'
    assert_includes main, 'axum_dsl_editable_set(attrs, "content", axum_dsl_json_string(&content));'
    assert_includes main, %q('<' => out.push_str("\\\\u003c"),)
    assert_includes main, %q('>' => out.push_str("\\\\u003e"),)
    assert_includes main, %q('&' => out.push_str("\\\\u0026"),)
    assert_includes main, %q(buf.push_str("value=\""))
    assert_includes main, "if editable.chars().all(char::is_whitespace)"
  end

  def test_a_crate_that_does_not_use_editable_does_not_emit_its_runtime
    main = compile_site(VIEW, dsl: SITE_HEAD + DRAWING + ROUTE_HOST)["src/main.rs"]
    refute_includes main, "axum_dsl_editable_attribute"
    refute_includes main, "axum_dsl_json_string"
  end

  def test_editable_needs_a_sanitizer_that_lists_both_partials
    msg = editable_refusal(EDITABLE_VIEW, dsl: EDITABLE_DSL.sub(", \"#{MENTION}\" => :mention", ""))
    assert_includes msg, "`|editable :message_body` rebuilds the attachments of a body"
    assert_includes msg, MENTION
  end

  def test_editable_names_an_undeclared_sanitizer
    assert_includes editable_refusal("{{ body|editable :nope, host: base, mentions: users }}\n"), "`|editable :nope` names no `sanitizer :nope`"
  end

  def test_editable_needs_the_host_and_the_users
    assert_includes editable_refusal("{{ body|editable :message_body }}{{ base }}{% for u in users %}{% endfor %}\n"), "renders attachments"
    assert_includes editable_refusal("{{ body|editable :message_body, host: base }}{% for u in users %}{% endfor %}\n"), "draws mentions, which need the users"
  end

  def test_editable_needs_a_string
    assert_includes editable_refusal("{{ body }}{{ users|editable :message_body, host: base, mentions: users }}\n"), "needs a string"
  end
end

