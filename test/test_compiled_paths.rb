# frozen_string_literal: true

# The compiler paths docs/coverage.md recorded as "not yet asserted", each proved by compiling a small DSL
# string (and the view files it reads) and asserting on the emitted Rust. No cargo and no HTTP: it runs in
# the `test-ruby` gate. The refusal halves live under test/refusals/ (views_partial_trailing_comma.rb,
# form_list_field.rb, form_map_field.rb, form_object_field.rb).
#
#   ruby -Ilib test/test_compiled_paths.rb
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "axum_dsl"

class TestCompiledPaths < Minitest::Test
  HEAD = <<~RB
    server "paths", version: "0.1.0"
    set :port, 8080
  RB

  # Compiles `body` (appended to a server header) beside the view files in `views` ({ "views/x.html" => text }),
  # and returns every emitted file ({ "src/main.rs", "Cargo.toml", ... }).
  def compile_files(body, views: {}, head: HEAD, extra: {})
    Dir.mktmpdir("paths") do |dir|
      (views.to_a + extra.to_a).each do |rel, text|
        FileUtils.mkdir_p(File.dirname(File.join(dir, rel)))
        File.write(File.join(dir, rel), text)
      end
      file = File.join(dir, "paths.axum.rb")
      File.write(file, head + body)
      AxumDsl::Emit.files(AxumDsl.read(file), file)
    end
  end

  # The emitted src/main.rs, which is what most of these tests read.
  def compile(body, views: {}, head: HEAD) = compile_files(body, views: views, head: head)["src/main.rs"]

  # `set :views` is a server setting: a render in a use_dsl fragment reads the server file's views/ folder,
  # not a views/ folder beside the fragment.
  def test_a_fragment_renders_a_view_from_the_server_folder
    frag = <<~RB
      fragment do
        get "/" do
          render :home, locals: { title: "Hi" }
        end
      end
    RB
    files = compile_files(%(use_dsl "controllers/home.axum.rb"\n),
                          extra: { "controllers/home.axum.rb" => frag },
                          views: { "views/home.html" => "{{ title }}\n" })
    assert_includes files["src/main.rs"], "route_1", "the fragment's route is emitted"
  end

  # A layout is a view too: `set :layout` in a fragment reads the server file's views/ folder, like the
  # render that inherits it.
  def test_a_fragment_layout_reads_the_server_folder
    frag = <<~RB
      fragment do
        set :layout, :app

        get "/" do
          render :home, locals: { title: "Hi" }
        end
      end
    RB
    files = compile_files(%(use_dsl "controllers/home.axum.rb"\n),
                          extra: { "controllers/home.axum.rb" => frag },
                          views: { "views/home.html" => "{{ title }}\n",
                                   "views/app.html" => "<main>{{ yield }}</main>\n" })
    assert_includes files["src/main.rs"], "route_1", "the fragment's route is emitted with its layout"
  end

  def test_a_multi_part_params_group_merges_each_parts_errors
    main = compile(<<~RB)
      params :Item do
        field :id, :i64, in: :path, min: 1
        field :name, :string, in: :body, min_length: 2
      end

      put "/items/:id", params: :Item do
        text(errors[:name])
      end
    RB
    assert_includes main, "let mut __errors = std::collections::BTreeMap::new();"
    assert_equal 2, main.scan("__errors.extend(match ").size, "one merge per part of the group (path and body)"
  end

  def test_an_all_raw_body_emits_no_escaper
    main = compile(<<~RB)
      params :Q do
        field :name, :string, in: :query
      end

      get "/raw", params: :Q do
        html("<p>\#{raw(params[:name])}</p>")
      end
    RB
    refute_includes main, "axum_dsl_html_escape", "raw(...) is the unescaped door: nothing escapes, so no escaper"
    assert_includes main, "<p>", "the body still writes its markup"
    assert_includes compile(<<~RB), "fn axum_dsl_html_escape", "control: h(...) does emit the escaper"
      params :Q do
        field :name, :string, in: :query
      end

      get "/esc", params: :Q do
        html("<p>\#{h(params[:name])}</p>")
      end
    RB
  end

  def test_raw_inside_a_partial
    views = {
      "views/home.html" => "<main>{{ partial :frag, body: markup }}</main>\n",
      "views/frag.html" => "<i>{{ body|raw }}</i>{% raw %}{{ keep }}{% endraw %}\n"
    }
    main = compile(<<~RB, views: views)
      get "/" do
        render :home, locals: { markup: "<b>x</b>" }
      end
    RB
    # `{{ keep }}` is no marker, so no local feeds it (a marker would make the render refuse); the braces
    # are doubled because the view is a format! string.
    assert_includes main, "{{{{ keep }}}}"
    refute_includes main, "axum_dsl_html_escape", "the partial's only marker is |raw, so nothing is escaped"
  end

  def test_a_partial_that_takes_no_arguments
    views = {
      "views/home.html" => "<p>top</p>{{ partial :rule }}\n",
      "views/rule.html" => "<hr>\n"
    }
    main = compile(<<~RB, views: views)
      get "/" do
        render :home
      end
    RB
    assert_includes main, "<hr>", "the partial's text is inlined"
  end

  # `{% args %}` partial fixtures: the partial text is `args`, called from `call`.
  def args_main(args, call, body: "<i>{{ label }}</i><b>{{ hint }}</b>")
    compile(%(get "/" do\n  render :home\nend\n),
            views: { "views/home.html" => "#{call}\n", "views/f.html" => "{% args #{args} %}#{body}\n" })
  end

  def args_refusal(args, call, body: "<i>{{ label }}</i><b>{{ hint }}</b>")
    assert_raises(AxumDsl::CompileError) { args_main(args, call, body: body) }.message
  end

  def test_an_omitted_args_default_is_used
    main = args_main('label:, hint: "none"', '{{ partial :f, label: "A" }}')
    assert_includes main, "none"
    refute_includes main, "{% args", "the declaration writes nothing"
  end

  def test_a_passed_args_value_overrides_the_default
    main = args_main('label:, hint: "none"', '{{ partial :f, label: "A", hint: "given" }}')
    assert_includes main, "given"
    refute_includes main, "none"
  end

  def test_args_defaults_may_be_integers_and_booleans
    main = args_main("label:, hint: -3", '{{ partial :f, label: "A" }}')
    assert_includes main, "-3"
  end

  def test_args_missing_a_required_argument_is_refused
    assert_includes args_refusal('label:, hint: ""', '{{ partial :f, hint: "x" }}'), "`{{ label }}` reads an argument"
  end

  def test_args_an_undeclared_argument_is_refused
    msg = args_refusal('label:, hint: ""', '{{ partial :f, label: "A", extra: "x" }}')
    assert_includes msg, "`extra` is passed to views/f.html but no marker reads it"
  end

  def test_args_naming_a_name_no_marker_reads_is_refused
    msg = args_refusal('label:, hint: "", more: ""', '{{ partial :f, label: "A" }}')
    assert_includes msg, "declares `more` but no marker reads it"
  end

  def test_a_marker_reading_an_undeclared_name_is_refused
    msg = args_refusal("label:", '{{ partial :f, label: "A" }}')
    assert_includes msg, "`hint` is read here but `{% args %}`"
  end

  def test_a_bad_args_default_is_refused
    assert_includes args_refusal("label:, hint: String.new", '{{ partial :f, label: "A" }}'), "not a literal"
    assert_includes args_refusal("label, hint: 1", '{{ partial :f, label: "A" }}'), "not a keyword"
  end

  def test_two_args_declarations_are_refused
    msg = args_refusal("label:, hint: 1", '{{ partial :f, label: "A" }}', body: "{% args label: %}{{ label }}{{ hint }}")
    assert_includes msg, "writes `{% args %}` once"
  end

  def test_args_in_a_view_rendered_directly_is_refused
    assert_raises(AxumDsl::CompileError) { compile(%(get "/" do\n  render :home\nend\n), views: { "views/home.html" => "{% args %}x\n" }) }
  end

  # `{% for %}`: a route that renders `notes` (a database record list) through views/home.html.
  NOTES = <<~RB
    database :sqlite, path: "x.db"

    record :Note do
      field :id, :i64
      field :body, :string
      field :tag, :string, optional: true
    end

    query :recent_notes, args: { limit: :i64 }, returns: list(:Note), sql: "SELECT id, body, tag FROM notes LIMIT :limit"

    get "/" do
      render :home, locals: { notes: recent_notes(limit: 20) }
    end
  RB

  def notes_main(view, views: {}) = compile(NOTES, views: views.merge("views/home.html" => view))

  def notes_refusal(view) = assert_raises(AxumDsl::CompileError) { notes_main(view) }.message

  # `transaction do ... end`: one db_tx around the block, whose statements call the sync `_on` core on `__tx`
  # rather than the pooled async wrapper; the block's final local is its value.
  def test_a_transaction_runs_statements_on_one_connection
    main = compile(<<~RB)
      database :sqlite, path: "x.db"

      query :count_messages, args: {}, returns: :i64, sql: "SELECT COUNT(*) FROM messages"
      execute :touch_message, args: { id: :i64 }, sql: "UPDATE messages SET body = body WHERE id = :id"

      post "/messages" do
        message_id = transaction do
          id = count_messages
          touch_message(id: id)
          id
        end
        text(message_id.to_s)
      end
    RB
    assert_includes main, 'let __out = db_tx("transaction", move |__tx| {'
    assert_includes main, "async fn db_tx<T: Send + 'static>(", "the crate gets db_tx only because a body opens one"
    refute_includes main, "async fn query_count_messages(", "a transaction-only statement has no pooled wrapper"
    assert_includes main, "let id = query_count_messages_on(__tx)?;"
    assert_includes main, "query_touch_message_on(__tx, id)?;"
    assert_includes main, "Ok(id) }).await?; __out }"
    assert_includes main, "fn query_count_messages_on(__c: &rusqlite::Connection) -> rusqlite::Result<i64> {"
    refute_includes main, "async fn query_touch_message(", "an execute used only in the transaction has no pooled wrapper"
    refute_includes main, 'db_run("count_messages"', "the pooled wrapper is omitted, not merely dead"
    refute_includes main, 'db_run("touch_message"', "the execute wrapper is omitted too"
    refute_includes main, "query_count_messages().await?", "inside the block the pooled wrapper is not called"
    assert_includes main, "#[allow(dead_code)]\nasync fn db_run<T: Send + 'static>(", "with no wrapper, db_run is allowed dead"
  end

  # A route rendering views/home.html with the string list `names` and the integer list `ns`.
  def lists_main(view, views: {}, locals: '{ names: ["a", "b"], ns: [1, 2] }')
    compile(%(get "/" do\n  render :home, locals: #{locals}\nend\n), views: views.merge("views/home.html" => view))
  end

  def lists_refusal(view, locals: '{ names: ["a", "b"] }')
    assert_raises(AxumDsl::CompileError) do
      compile(%(get "/" do\n  render :home, locals: #{locals}\nend\n), views: { "views/home.html" => view })
    end.message
  end

  # Nil narrowing: after `.nil?` a nil-able local is non-nil where the test says so.
  NARROW_NOTES = <<~RB
    database :sqlite, path: "x.db"

    record :Note do
      field :id, :i64
      field :body, :string
    end

    query :find_note, args: { id: :i64 }, returns: :Note?, sql: "SELECT id, body FROM notes WHERE id = :id"

  RB

  def narrow(body, head: "") = compile(head + body)

  def narrow_refusal(body, head: "") = assert_raises(AxumDsl::CompileError) { narrow(body, head: head) }.message

  def test_if_nil_else_reads_the_local_as_non_nil
    main = narrow(<<~RB)
      get "/first" do
        names = ["a", "b"]
        first = names.first
        if first.nil?
          text("none")
        else
          text(first)
        end
      end
    RB
    # Nothing reads `first` after the if, so the match moves it rather than cloning it.
    assert_match(/match first \{ None => \{ .*\}, Some\(first\) => \{ .*first.* \} \}/, main)
    refute_includes main, "unwrap()", "narrowing is panic-free"
    neg = narrow(<<~RB)
      get "/first" do
        names = ["a", "b"]
        first = names.first
        if !first.nil?
          text(first)
        else
          text("none")
        end
      end
    RB
    assert_match(/Some\(first\) => \{ /, neg)
    unl = narrow(<<~RB)
      get "/first" do
        names = ["a", "b"]
        first = names.first
        unless first.nil?
          text(first)
        else
          text("none")
        end
      end
    RB
    assert_match(/None => \{ .*\}, Some\(first\)/, unl)
  end

  def test_if_nil_else_on_a_record
    main = narrow(NARROW_NOTES + <<~RB)
      get "/n" do
        note = find_note(id: 1)
        if note.nil?
          halt(404, "no such note")
        else
          json(note)
        end
      end
    RB
    assert_match(/match note \{ None => \{ .*\}, Some\(note\) => \{ .* \} \}/, main)
  end

  # Inside a transaction a statement's arguments are lowered in the block's `move` closure, after BEGIN, so
  # they may only read what already exists: a local, a field read and `params[...]` pass; a call is refused.
  def test_a_transaction_statement_argument_may_read_a_local_and_a_field
    main = narrow(NARROW_NOTES + <<~RB)
      params :MessageIn do
        field :body, :string, in: :form
      end

      query :count_notes, args: {}, returns: :i64, sql: "SELECT COUNT(*) FROM notes"
      execute :touch_note, args: { id: :i64, body: :string }, sql: "UPDATE notes SET body = :body WHERE id = :id"

      post "/notes", params: :MessageIn do
        note = find_note(id: 1)
        if note.nil?
          halt(404, "no such note")
        else
          note_id = note.id
          count = transaction do
            touch_note(id: note.id, body: params[:body])
            touch_note(id: note_id, body: note.body)
            count_notes
          end
          text(count.to_s)
        end
      end
    RB
    assert_includes main, "query_touch_note_on(__tx, note.id, body.clone())?;", "a field read and params[...] pass"
    assert_includes main, "query_touch_note_on(__tx, note_id, note.body.clone()", "a local and a field read pass"
    assert_includes main, "Ok(query_count_notes_on(__tx)?)", "a statement call still ends the block"
  end

  def test_an_unread_non_nil_binding_is_underscore
    main = narrow(<<~RB)
      get "/first" do
        names = ["a", "b"]
        first = names.first
        if first.nil?
          text("none")
        else
          text("some")
        end
      end
    RB
    assert_match(/match first \{ None => .*, Some\(_\) => /, main)
  end

  def test_an_elsif_after_the_narrowing_condition_sees_non_nil
    main = narrow(<<~RB)
      get "/first" do
        names = ["a", "b"]
        first = names.first
        if first.nil?
          text("none")
        elsif first == "a"
          text("a")
        else
          text(first)
        end
      end
    RB
    assert_includes main, "Some(first) =>"
  end

  def test_a_ternary_narrows_like_if
    main = narrow(<<~RB)
      get "/first" do
        names = ["a", "b"]
        first = names.first
        text(first.nil? ? "none" : first)
      end
    RB
    assert_includes main, "Some(first) =>"
  end

  # A query record derives Clone, so a narrowed record that is read again after the `if` is cloned, not moved.
  def test_a_narrowed_record_read_after_the_if_is_cloned
    main = narrow(NARROW_NOTES + <<~RB)
      get "/n" do
        note = find_note(id: 1)
        label = if note.nil? then "none" else note.body end
        again = note.nil? ? "none" : note.body
        text(label + again)
      end
    RB
    assert_includes main, "match note.clone() {"
  end

  def test_a_guard_narrows_the_rest_of_the_body
    main = narrow(NARROW_NOTES + <<~RB)
      get "/n" do
        note = find_note(id: 1)
        return halt(404, "no such note") if note.nil?
        json(note)
      end

      get "/r" do
        names = ["a"]
        first = names.first
        raise "empty" if first.nil?
        text(first)
      end

      get "/s" do
        names = ["a"]
        first = names.first
        return text("none") if first.nil?
        text(first)
      end
    RB
    assert_includes main, "let note = match note { Some(__v) => __v, None => return Ok("
    assert_includes main, "let first = match first { Some(__v) => __v, None => return Err("
    # The narrowed locals are never unwrapped (halt's own literal StatusCode::from_u16(404).unwrap() is not one).
    refute_match(/\b(note|first)\.(unwrap|expect)\(/, main)
  end

  def test_a_compound_condition_does_not_narrow
    msg = narrow_refusal(<<~RB)
      get "/first" do
        names = ["a", "b"]
        first = names.first
        if !first.nil? && first == "a"
          text(first)
        else
          text("none")
        end
      end
    RB
    refute_empty msg, "the nil-able local is still refused where the test does not narrow it"
  end

  def test_the_nil_branch_still_sees_a_nil_able_local
    msg = narrow_refusal(<<~RB)
      get "/first" do
        names = ["a", "b"]
        first = names.first
        if first.nil?
          text(first)
        else
          text("some")
        end
      end
    RB
    refute_empty msg, "the nil-able local is still refused where the test does not narrow it"
  end

  def test_a_loop_over_records
    main = notes_main("<ul>{% for note in notes %}<li id=\"note-{{ note.id }}\">{{ note.body }}{{ note.body|raw }}</li>{% endfor %}</ul>\n")
    assert_includes main, "for __it_note in &"
    assert_includes main, "axum_dsl_html_escape(&__it_note.id.to_string()).into_owned()", "an integer field is formatted, then escaped"
    assert_includes main, "axum_dsl_html_escape(&__it_note.body).into_owned()", "a string field is escaped as the plain markers do"
    assert_includes main, "__it_note.body.to_string()", "|raw writes the field as it is"
    assert_includes main, "note-{}"
  end

  def test_a_loop_over_scalar_lists
    main = lists_main("{% for n in names %}<i>{{ n }}</i>{{ n|raw }}{% endfor %}{% for m in ns %}{{ m }},{% endfor %}\n")
    assert_includes main, "axum_dsl_html_escape(__it_n.as_str()).into_owned()"
    assert_includes main, "__it_n.as_str().to_string()"
    assert_includes main, "axum_dsl_html_escape(&__it_m.to_string()).into_owned()"
  end

  def test_nested_loops
    main = lists_main("{% for n in names %}{% for m in ns %}{{ n }}{{ m }}{% endfor %}{% endfor %}\n")
    assert_includes main, "for __it_n in &"
    assert_includes main, "for __it_m in &"
    assert_equal 2, main.scan("let mut __s = String::new();").size, "one accumulator per loop"
  end

  def test_a_loop_over_a_field_of_the_enclosing_loop_variable
    main = compile(<<~RB, views: { "views/home.html" => "{% for g in groups %}{% for t in g.tags %}{{ t }}{% endfor %}{% endfor %}\n" })
      params :Group do
        field :tags, :string_list
      end

      params :Page do
        field :groups, list(:Group)
      end

      post "/p", params: :Page do
        render :home, locals: { groups: params[:groups] }
      end
    RB
    assert_includes main, "for __it_t in &__it_g.tags"
  end

  def test_a_raw_region_inside_a_loop_is_kept_byte_for_byte
    main = lists_main("{% for n in names %}{% raw %}{{ keep }}{{ n }}{% endraw %}{% endfor %}\n", locals: '{ names: ["a"] }')
    assert_includes main, 'push_str("{{ keep }}{{ n }}")', "no marker in the body, so the text is pushed as it is"
  end

  def test_a_loop_in_a_partial_and_in_a_layout
    views = {
      "views/list.html" => "{% args items: %}{% for i in items %}<b>{{ i }}</b>{% endfor %}\n",
      "views/app.html" => "<ul>{% for n in names %}<li>{{ n }}</li>{% endfor %}</ul>{{ yield }}\n"
    }
    main = compile(%(get "/" do\n  render :home, layout: :app, locals: { names: ["a"], ns: [1] }\nend\n),
                   views: views.merge("views/home.html" => "{{ partial :list, items: ns }}\n"))
    assert_includes main, "for __it_i in &"
    assert_includes main, "for __it_n in &"
  end

  # `{% if %}`: a bool local is the Rust condition and each arm's markup sits in its own branch. The two
  # routes pass the same view different literals -- the precondition is the `locals:` hash, an ordinary body
  # expression -- so both polarities are compiled.
  def test_an_if_and_else_compile_to_a_rust_branch
    view = %(<p>top</p>{% if show %}<p class="shown">shown</p>{% else %}<p class="hidden">hidden</p>{% endif %}\n)
    main = compile(<<~RB, views: { "views/home.html" => view })
      get "/on" do
        show = true
        render :home, locals: { show: show }
      end

      get "/off" do
        show = false
        render :home, locals: { show: show }
      end
    RB
    assert_equal 2, main.scan("if show {").size, "one branch per render, true and false"
    taken, otherwise = main.split("} else {", 2)
    assert_includes taken, "shown", "the taken arm is the if's body"
    refute_includes taken, "hidden", "the other arm is not in it"
    assert_includes otherwise, "hidden"
  end

  # Both branches' markers are the render's locals, whether or not a branch is taken at run time, and the
  # condition's own name is one too. The precondition is a locals hash that passes all three.
  def test_both_branches_of_an_if_are_the_renders_locals
    main = compile(<<~RB, views: { "views/home.html" => "{% if show %}{{ yes }}{% else %}{{ no }}{% endif %}\n" })
      get "/" do
        show = true
        render :home, locals: { show: show, yes: "y", no: "n" }
      end
    RB
    assert_includes main, "if show {"
    assert_includes main, "axum_dsl_html_escape("
  end

  # A nil-able condition is true when it is not nil, and the taken branch reads the value: the emitted guard
  # is an `if let`, and `{{ first }}` inside it is the binding, never an `unwrap`.
  def test_a_nil_able_condition_narrows_inside_the_branch
    main = compile(<<~RB, views: { "views/home.html" => "{% if first %}<b>{{ first }}</b>{% endif %}\n" })
      get "/" do
        names = ["a", "b"]
        first = names.first
        render :home, locals: { first: first }
      end
    RB
    assert_includes main, "if let Some(__if_first) = first.as_deref() {"
    assert_includes main, "axum_dsl_html_escape(__if_first).into_owned()"
    refute_match(/\bfirst\.(unwrap|expect)\(/, main)
  end

  # `{% if %}` nests and wraps a `{% for %}`: each open block restores the list the next segment goes in.
  def test_an_if_around_a_loop_and_a_nested_if
    view = "{% if show %}{% for n in names %}<b>{{ n }}</b>{% endfor %}{% else %}{% if again %}<i>none</i>{% endif %}{% endif %}\n"
    main = compile(%(get "/" do\n  show = true\n  again = false\n  names = ["a"]\n  render :home, locals: { show: show, again: again, names: names }\nend\n),
                   views: { "views/home.html" => view })
    assert_includes main, "if show {"
    assert_includes main, "if again {"
    assert_includes main, "for __it_n in &"
    assert_equal 3, main.scan("let mut __s = String::new();").size, "one accumulator per if and loop"
  end

  # `{% if %}` inside a loop takes a bool field and a nil-able field, and the nil-able field narrows inside
  # its branch under its spelled key: `{{ t.note }}` is the `if let` binding, not the optional field.
  def test_an_if_inside_a_loop_narrows_a_nil_able_field
    view = "{% for t in tasks %}{% if t.done %}<b class=\"done\">{{ t.title }}</b>{% else %}<i>{{ t.title }}</i>" \
           "{% endif %}{% if t.note %}<small>{{ t.note }}</small>{% endif %}{% endfor %}\n"
    main = compile(<<~RB, views: { "views/home.html" => view })
      params :Task do
        field :done, :bool
        field :title, :string
        field :note, :string, optional: true
      end

      params :Page do
        field :tasks, list(:Task)
      end

      post "/p", params: :Page do
        render :home, locals: { tasks: params[:tasks] }
      end
    RB
    assert_includes main, "if __it_t.done {"
    assert_includes main, "if let Some(__if_t_note) = __it_t.note.as_deref() {"
    assert_includes main, "axum_dsl_html_escape(__if_t_note).into_owned()"
  end

  # `|sanitize`: a string local goes to the compiler's sanitiser with no escaper around it, and the crate gains
  # the helper and ammonia only because this view uses it.
  def test_sanitize_emits_the_helper_and_the_dependency
    files = compile_files(<<~RB, views: { "views/home.html" => "{{ body|sanitize }}\n" })
      params :Post do
        field :body, :string, in: :form
      end

      post "/", params: :Post do
        body = params[:body]
        render :home, locals: { body: body }
      end
    RB
    main = files["src/main.rs"]
    assert_includes main, "axum_dsl_sanitize(&body)"
    assert_includes main, "fn axum_dsl_sanitize(html: &str) -> String", "the helper is emitted only for this use"
    assert_includes main, "add_generic_attributes(&[\"class\"])", "Action Text/Trix classes survive"
    refute_includes main, "axum_dsl_html_escape", "sanitize does not escape: no escaper around the value"
    assert_includes files["Cargo.toml"], "ammonia = \"4\""
  end

  # The escaped and unchecked forms are unchanged, and a crate that never sanitises gets neither the helper nor
  # the dependency.
  def test_escaped_and_raw_markers_are_unchanged
    files = compile_files(<<~RB, views: { "views/home.html" => "{{ body }}{{ body|raw }}\n" })
      params :Post do
        field :body, :string, in: :form
      end

      post "/", params: :Post do
        body = params[:body]
        render :home, locals: { body: body }
      end
    RB
    main = files["src/main.rs"]
    assert_includes main, "axum_dsl_html_escape(&body).into_owned()"
    assert_includes main, "body.to_string()", "|raw writes the value as it is"
    refute_includes main, "axum_dsl_sanitize"
    refute_includes main, "fn axum_dsl_sanitize"
    refute_includes files["Cargo.toml"], "ammonia"
  end

  def test_a_loop_variable_or_its_field_may_be_a_partial_argument
    views = { "views/cell.html" => "<td>{{ v }}</td>\n" }
    main = notes_main("{% for note in notes %}{{ partial :cell, v: note.body }}{{ partial :cell, v: note.id }}{% endfor %}\n", views: views)
    assert_includes main, "&__it_note.body"
    main = lists_main("{% for n in names %}{{ partial :cell, v: n }}{% endfor %}{% for m in ns %}{{ partial :cell, v: m }}{% endfor %}\n", views: views)
    assert_includes main, "axum_dsl_html_escape(__it_n.as_str())"
    assert_includes main, "axum_dsl_html_escape(&__it_m.to_string())"
  end

  def test_loop_refusals_in_the_view
    assert_includes lists_refusal("{% for n in names %}{{ n }}\n"), "views/home.html:1: this `{% for n in ... %}` is never closed"
    assert_includes lists_refusal("{{ names }}\n{% endfor %}\n"), "views/home.html:2: `{% endfor %}` here has no `{% for %}`"
    assert_includes lists_refusal("{% for n in names %}{{ n }}{% endfor %}\n{{ n }}\n"), "views/home.html:2: `n` is a loop variable used outside its `{% for %}`"
    assert_includes lists_refusal("{% for n in names %}{% for n in names %}{% endfor %}{% endfor %}\n"), "already the variable of an enclosing"
    assert_includes lists_refusal("{% for n of names %}{% endfor %}\n"), "is not a loop"
    assert_includes lists_refusal("{% for N in names %}{% endfor %}\n"), "a new snake_case name"
    assert_includes lists_refusal("{% for n in names %}{{ yield }}{% endfor %}\n"), "cannot sit inside a `{% for %}`"
    assert_includes lists_refusal("{% for n in names %}{{ n.a.b }}{% endfor %}\n"), "more than one dot"
  end

  def test_loop_refusals_with_the_locals
    assert_includes lists_refusal("{% for n in names %}{{ n }}{% endfor %}\n", locals: '{ names: "abc" }'), "not a list"
    assert_includes lists_refusal("{% for n in names %}{{ n.len }}{% endfor %}\n"), "which has no fields"
    assert_includes lists_refusal("{{ n }}{% for n in names %}{{ n }}{% endfor %}\n", locals: '{ names: ["a"], n: "x" }'),
                    "`n` is already a local"
    assert_includes lists_refusal("{% for n in names %}{{ n }}{% endfor %}\n", locals: '{ names: ["a"], ns: [1] }'), "`ns` is passed to this render but no marker reads it"
  end

  def test_loop_refusals_on_fields
    assert_includes notes_refusal("{% for note in notes %}{{ note.bdy }}{% endfor %}\n"), "Note has no field `bdy` (its fields: id, body, tag)"
    assert_includes notes_refusal("{% for note in notes %}{{ note.tag }}{% endfor %}\n"), "`note.tag` is optional and may be nil"
    assert_includes notes_refusal("{% for note in notes %}{{ note }}{% endfor %}\n"), "write one of its fields: {{ note.id }}, {{ note.body }}"
  end

  def test_a_non_default_views_folder
    views = { "pages/home.html" => "<p>from the pages folder</p>\n" }
    main = compile(<<~RB, views: views, head: HEAD + "set :views, \"pages\"\n")
      get "/" do
        render :home
      end
    RB
    assert_includes main, "from the pages folder"
  end

  def test_an_integer_status_in_a_route
    main = compile(<<~RB)
      post "/made" do
        status(201)
        text("made")
      end
    RB
    assert_includes main, "*__stated.status_mut() = ::axum::http::StatusCode::from_u16(201).unwrap();"
  end

  def test_a_status_in_a_before_filter_that_continues_is_applied_to_the_passed_through_response
    main = compile(<<~RB)
      before do
        status(:accepted)
        "ok"
      end

      get "/" do
        text("hi")
      end
    RB
    ran = main.index("next.run(request).await") or flunk "the filter does not pass the request on"
    set = main.index("*response.status_mut() = ::axum::http::StatusCode::ACCEPTED;") or
      flunk "the filter's status is not applied to the response"
    assert_operator set, :>, ran, "the status is set on the response the route answered with, after it ran"
    int = compile("before do\n  status(202)\n  \"ok\"\nend\n\nget \"/\" do\n  text(\"hi\")\nend\n")
    assert_includes int, "*response.status_mut() = ::axum::http::StatusCode::from_u16(202).unwrap();"
  end

  # A `file` is copied into the crate at its declared path and named there by that relative path, so the
  # binary does not look for the build machine's directory.
  def test_a_file_is_copied_into_the_crate_and_named_by_its_relative_path
    Dir.mktmpdir("paths") do |dir|
      bytes = "caf\xC3\xA9\r\nline two\n\x00tail".b
      FileUtils.mkdir_p(File.join(dir, "hatches"))
      File.binwrite(File.join(dir, "hatches", "motd.txt"), bytes)
      src = File.join(dir, "paths.axum.rb")
      File.write(src, HEAD + <<~RB)
        file "hatches/motd.txt", as: :motd

        get "/motd" do
          text(file_text(:motd))
        end
      RB
      files = AxumDsl::Emit.files(AxumDsl.read(src), src)
      main = files["src/main.rs"]
      assert_includes main, 'std::path::PathBuf::from("hatches/motd.txt")'
      refute_includes main, dir, "the build machine's absolute path is not baked into main.rs"
      refute_includes main, File.realpath(dir)
      assert_equal bytes, files["hatches/motd.txt"].b, "the copy is byte for byte"
    end
  end

  # GAPS 9: use_layer :rate_limit is the compiler's own fixed-window limiter. Its three values are
  # constants in the emitted crate; the layer is axum middleware and needs no tower-http feature.
  def test_rate_limit_layer_emits_its_window_and_runtime
    files = compile_files(<<~RB)
      use_layer :rate_limit, per: 180, burst: 10, path: "/session"

      post "/session" do
        text("ok")
      end
    RB
    main = files["src/main.rs"]
    assert_includes main, "const AXUM_DSL_RATE_LIMIT_PER: u64 = 180;"
    assert_includes main, "const AXUM_DSL_RATE_LIMIT_BURST: u32 = 10;"
    assert_includes main, %(const AXUM_DSL_RATE_LIMIT_PATH: &str = "/session";)
    assert_includes main, ".layer(::axum::middleware::from_fn(axum_dsl_rate_limit))"
    assert_includes main, "::axum::http::StatusCode::TOO_MANY_REQUESTS"
    assert_includes main, "fn axum_dsl_request_ip(_headers:", "the limiter keys on the sessions runtime's request_ip"
    refute_includes files["Cargo.toml"], "tower-http", "the limiter needs no tower-http feature"

    all = compile(%(use_layer :rate_limit, per: 60, burst: 3\n\nget "/" do\n  text("ok")\nend\n))
    assert_includes all, %(const AXUM_DSL_RATE_LIMIT_PATH: &str = "";), "without path: every route is counted"
  end

  # GAPS 13: a form field may carry a Rails wire name (`message[body]`), a serde rename on the struct
  # field. The DSL name is unchanged for params[:body], check() and errors.
  def test_a_form_field_name_renames_the_wire_key_only
    main = compile(<<~RB)
      params :Message do
        field :body, :string, in: :form, name: "message[body]", min_length: 1
      end

      post "/messages", params: :Message do
        text(params[:body])
      end
    RB
    assert_includes main, '#[serde(rename = "message[body]")]'
    assert_includes main, "body: String,"
    assert_includes main, %q{"body", v.chars().count()}, "the generated check is keyed by the DSL name"
    refute_includes main, "for message[body]", "the wire key does not leak into the message"
  end

  # GAPS 11b: etag(value) is a route statement. The emitter sets ETag and answers a matching
  # If-None-Match with 304 and no body; the value is computed at run time.
  def test_etag_sets_the_header_and_answers_304_on_a_match
    main = compile(<<~RB)
      get "/etag" do
        etag("v1")
        text("fresh")
      end
    RB
    assert_includes main, %(let __etag = "v1".to_string();)
    assert_includes main, "::axum::http::header::IF_NONE_MATCH"
    assert_includes main, "::axum::http::StatusCode::NOT_MODIFIED"
    assert_includes main, "::axum::http::header::ETAG"
    assert_includes main, "__headers: ::axum::http::HeaderMap", "the route takes the headers it compares"
  end
end
