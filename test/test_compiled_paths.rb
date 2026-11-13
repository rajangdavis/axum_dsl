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

  # The refusal message, for the rules a compiled-path test also pins.
  def refusal(body, head: HEAD, extra: {})
    error = assert_raises(AxumDsl::CompileError) { compile_files(body, head: head, extra: extra) }
    error.message
  end

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
    # `{{ keep }}` is no marker, so no local feeds it (a marker would make the render refuse); it is
    # literal text, pushed as it is.
    assert_includes main, "{{ keep }}"
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

  # ERB under Erubi trim mode drops a line that holds only a `<%# %>` tag, newline included; `{% args %}` alone on
  # its line is the same: the partial's text starts at the next line.
  def test_an_args_line_alone_leaves_no_newline_behind
    alone = compile(%(get "/" do\n  render :home\nend\n),
                    views: { "views/home.html" => %({{ partial :f, label: "A" }}\n), "views/f.html" => "{% args label: %}\n<b>{{ label }}</b>\n" })
    refute_includes alone, %(\\n<b>), "the declaration line's newline is not emitted"
    shared = compile(%(get "/" do\n  render :home\nend\n),
                     views: { "views/home.html" => %({{ partial :f, label: "A" }}\n), "views/f.html" => "{% args label: %} \n<b>{{ label }}</b>\n" })
    assert_includes shared, %(\\n<b>), "a declaration sharing its line with text keeps the newline after the text"
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

  # A page may declare `{% args %}` (defaults for its own locals); like a partial, it then lists exactly the names it reads.
  def test_args_in_a_view_rendered_directly_lists_what_the_view_reads
    compile(%(get "/" do\n  render :home\nend\n), views: { "views/home.html" => "{% args %}x\n" })
    assert_raises(AxumDsl::CompileError) do
      compile(%(get "/" do\n  render :home, locals: { name: "a" }\nend\n), views: { "views/home.html" => "{% args %}{{ name }}\n" })
    end
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

  # Writes (a statement that writes, and every `db_tx`) go to ONE writer thread as boxed closures with a oneshot reply,
  # as once-campfire-rust/crates/db/src/database.rs does: no async lock around them, no pooled connection to check out.
  def test_writes_run_on_one_writer_thread_with_no_lock_around_interact
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
        touch_message(id: message_id)
        total = count_messages
        text(total.to_s)
      end
    RB
    assert_includes main, "type DbWrite = Box<dyn FnOnce(&mut rusqlite::Connection) + Send>;"
    assert_includes main, "static DB_WRITER: std::sync::OnceLock<std::sync::mpsc::Sender<DbWrite>>"
    assert_includes main, '.name("db-writer".into())'
    assert_includes main, "async fn db_write<T: Send + 'static>("
    assert_includes main, 'db_write("query", name, move |__c| {', "db_run sends a write to the writer"
    assert_includes main, 'db_write("transaction", name, move |__c| {', "db_tx sends its IMMEDIATE transaction there"
    assert_includes main, "transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)"
    assert_includes main, "std::panic::catch_unwind", "a panicking write answers its caller and the writer lives on"
    refute_includes main, "DB_WRITE_LOCK", "writes queue on the writer thread, not behind an async lock"
    refute_includes main, ".interact(", "no pooled connection hand-off"
    refute_includes main, "deadpool_sqlite", "no pool in the emitted code"
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
  # The db_tx closure is `move`, so it would take the outer locals it reads; each one is cloned first, so the body can
  # still read it after the block (rustc E0382 otherwise: a token stored in the transaction, then set as a cookie).
  def test_a_transaction_clones_the_outer_locals_it_reads
    main = compile(<<~RB)
      database :sqlite, path: "x.db"

      execute :start_session, args: { token: :string }, sql: "INSERT INTO sessions (token) VALUES (:token)"

      post "/session" do
        token = random_token
        started = transaction do
          start_session(token: token)
        end
        text("\#{started} \#{token}")
      end
    RB
    assert_includes main, '{ let token = token.clone(); let __out = db_tx("transaction", move |__tx| {'
    assert_includes main, "query_start_session_on(__tx, token.clone())"
  end

  # A ternary passed to a query is one argument between commas, so it carries no parens of its own (rustc's
  # unused_parens, an error under -Dwarnings).
  def test_a_ternary_query_argument_has_no_parens
    main = compile(<<~RB)
      database :sqlite, path: "x.db"

      params :RoleIn do
        field :role, :string, in: :form
      end

      execute :set_role, args: { role: :i64 }, sql: "UPDATE users SET role = :role"

      post "/role", params: :RoleIn do
        set_role(role: params[:role] == "administrator" ? 1 : 0)
        text("ok")
      end
    RB
    assert_includes main, 'query_set_role(if role == "administrator" { 1 } else { 0 }).await?'
  end

  # params[:x] is the Rust binding `x`, so a later read past a local named `x` would see the local: refused.
  def test_a_local_may_not_hide_a_params_field_that_is_read_after_it
    src = <<~RB
      params :RoleIn do
        field :role, :string, in: :form
      end

      post "/role", params: :RoleIn do
        role = "admin"
        text(params[:role] + role)
      end
    RB
    err = assert_raises(AxumDsl::CompileError) { compile(src) }
    assert_includes err.message, "params[:role] is hidden here by the local `role`"
    assert_includes compile(src.gsub("role = \"admin\"", "kept = \"admin\"").gsub("+ role)", "+ kept)")), "kept"
    rebind = compile(src.gsub("role = \"admin\"", "role = params[:role]"))
    assert_includes rebind, "let role = role;", "rebinding the same value is allowed"
  end

  # A transaction run only for its effects stands as a statement; its value is dropped (`;`), so no local is left unread.
  def test_a_transaction_may_stand_as_a_statement
    main = compile(<<~RB)
      database :sqlite, path: "x.db"

      execute :touch_note, args: { id: :i64 }, sql: "UPDATE notes SET body = body WHERE id = :id"

      post "/touch" do
        transaction do
          touch_note(id: 1)
          touch_note(id: 2)
        end
        text("ok")
      end
    RB
    assert_includes main, 'let __out = db_tx("transaction", move |__tx| { query_touch_note_on(__tx, 1)?; Ok(query_touch_note_on(__tx, 2)?) }).await?; __out };'
  end

  # Narrowing an upload with `if x.nil? ... else x.store(...) end` binds it; a later read of x keeps it (a clone).
  def test_an_upload_narrowed_by_nil_is_still_there_afterwards
    main = compile(<<~RB)
      params :LogoIn do
        field :logo, :upload, in: :form
      end

      post "/logo", params: :LogoIn do
        logo = params[:logo]
        key = if logo.nil?
          ""
        else
          logo.store("/tmp")
        end
        text("\#{key} \#{logo.nil?}")
      end
    RB
    assert_includes main, "match logo.clone() {"
  end

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
    assert_includes main, "format_args!(\"{}\", __it_note.id)", "an integer field is written with its Display, which has nothing to escape"
    assert_includes main, "axum_dsl_html_escape_into(&mut __out, &__it_note.body)", "a string field is escaped as the plain markers do"
    assert_includes main, "__out.push_str(&__it_note.body)", "|raw writes the field as it is"
    assert_includes main, "<li id=\\\"note-"
  end

  def test_a_loop_over_scalar_lists
    main = lists_main("{% for n in names %}<i>{{ n }}</i>{{ n|raw }}{% endfor %}{% for m in ns %}{{ m }},{% endfor %}\n")
    assert_includes main, "axum_dsl_html_escape_into(&mut __out, __it_n.as_str())"
    assert_includes main, "__out.push_str(__it_n.as_str())"
    assert_includes main, "format_args!(\"{}\", __it_m)"
  end

  def test_nested_loops
    main = lists_main("{% for n in names %}{% for m in ns %}{{ n }}{{ m }}{% endfor %}{% endfor %}\n")
    assert_includes main, "for __it_n in &"
    assert_includes main, "for __it_m in &"
    assert_equal 1, main.scan("String::with_capacity(").size, "nested loops write into the render's one buffer"
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
    assert_includes main, "if show { __out.push_str(\"y\"); } else { __out.push_str(\"n\"); }", "literal locals are escaped by the compiler"
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
    assert_includes main, "axum_dsl_html_escape_into(&mut __out, __if_first)"
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
    assert_equal 1, main.scan("String::with_capacity(").size, "ifs and loops write into the render's one buffer"
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
    assert_includes main, "axum_dsl_html_escape_into(&mut __out, __if_t_note)"
  end

  # A comparison passed as a local is the whole `if` condition, so it takes no parentheses of its own: rustc's
  # unused_parens would fail the crate. The local is inlined as `(flags == 1)`, and only the outer pair goes.
  def test_a_comparison_local_is_an_if_condition_without_parens
    main = compile(<<~RB, views: { "views/home.html" => "{% if big %}<b>big</b>{% endif %}\n" })
      params :Size do
        field :n, :i64, in: :query
      end

      get "/", params: :Size do
        render :home, locals: { big: params[:n] == 1 }
      end
    RB
    assert_match(/\bif n == 1 \{/, main, "the comparison is the condition")
    refute_match(/\bif \(/, main, "and carries no parentheses")
  end

  EQ_PARAMS = <<~RB
    params :U do
      field :id, :i64
      field :name, :string
    end

    params :Q do
      field :a, :i64
      field :b, :i64
      field :s, :string
      field :t, :string
      field :f, :bool
      field :g, :bool
      field :x, :f64
      field :users, list(:U)
    end
  RB

  # A route that assigns exactly the locals it passes (an assigned local nothing reads is refused).
  def eq_body(locals)
    names = locals.scan(/(\w+):/).flatten
    EQ_PARAMS + "post \"/q\", params: :Q do\n#{names.map { |n| "  #{n} = params[:#{n}]\n" }.join}  render :home, locals: { #{locals} }\nend\n"
  end

  def eq_route(view, locals)
    compile(eq_body(locals),
            views: { "views/home.html" => view })
  end

  def eq_refusal(view, locals)
    refusal(eq_body(locals),
            extra: { "views/home.html" => view })
  end

  # `{% if a == b %}`: equality between two names, by value, with an `{% else %}` as for a one-name condition.
  def test_an_if_compares_two_integers_two_strings_and_two_bools
    assert_match(/\bif a == b \{/, eq_route("{% if a == b %}same{% else %}diff{% endif %}\n", "a: a, b: b"))
    assert_includes eq_route("{% if s == t %}same{% endif %}\n", "s: s, t: t"), "s.as_str() == t.as_str()"
    assert_match(/\bif f == g \{/, eq_route("{% if f == g %}same{% endif %}\n", "f: f, g: g"))
  end

  def test_an_if_compares_a_loop_field_with_a_local
    main = eq_route("{% for u in users %}{% if u.id == a %}<b>{{ u.name }}</b>{% else %}{{ u.name }}{% endif %}{% endfor %}\n", "users: users, a: a")
    assert_match(/\bif __it_u\.id == a \{/, main)
    main = eq_route("{% for u in users %}{% if u.name == s %}x{% endif %}{% endfor %}\n", "users: users, s: s")
    assert_includes main, "__it_u.name.as_str() == s.as_str()"
  end

  def test_an_equality_refuses_what_is_not_two_names_of_one_type
    assert_match(/\bif a != b \{/, eq_route("{% if a != b %}x{% endif %}\n", "a: a, b: b"))
    assert_match(/\bif a == 1 \{/, eq_route("{% if a == 1 %}x{% endif %}\n", "a: a"))
    assert_includes eq_refusal("{% if a == b == s %}x{% endif %}\n", "a: a, b: b, s: s"), "more than one comparison"
    assert_includes eq_refusal("{% if a && b %}x{% endif %}\n", "a: a, b: b"), "a condition is a `bool` or a nil-able value"
    msg = eq_refusal("{% if a == s %}x{% endif %}\n", "a: a, s: s")
    assert_includes msg, "Integer (i64)"
    assert_includes msg, "String"
    assert_includes eq_refusal("{% if x == x %}x{% endif %}\n", "x: x"), "Float"
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
    assert_includes main, "axum_dsl_sanitize_into(&mut __out, &body)"
    assert_includes main, "fn axum_dsl_sanitize_into(buf: &mut String, html: &str)", "the helper is emitted only for this use"
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
    assert_includes main, "axum_dsl_html_escape_into(&mut __out, &body)"
    assert_includes main, "__out.push_str(&body)", "|raw writes the value as it is"
    refute_includes main, "axum_dsl_sanitize"
    refute_includes main, "fn axum_dsl_sanitize"
    refute_includes files["Cargo.toml"], "ammonia"
  end

  def test_a_loop_variable_or_its_field_may_be_a_partial_argument
    views = { "views/cell.html" => "<td>{{ v }}</td>\n" }
    main = notes_main("{% for note in notes %}{{ partial :cell, v: note.body }}{{ partial :cell, v: note.id }}{% endfor %}\n", views: views)
    assert_includes main, "&__it_note.body"
    main = lists_main("{% for n in names %}{{ partial :cell, v: n }}{% endfor %}{% for m in ns %}{{ partial :cell, v: m }}{% endfor %}\n", views: views)
    assert_includes main, "axum_dsl_html_escape_into(&mut __out, __it_n.as_str())"
    assert_includes main, "format_args!(\"{}\", __it_m)"
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

  # `binary: true`: a file that is not UTF-8 (an image) is copied byte for byte and checked at startup as bytes;
  # it is sent by file_path, and file_text on it is refused.
  def test_a_binary_file_is_copied_and_never_read_as_text
    Dir.mktmpdir("paths") do |dir|
      bytes = "\x89PNG\r\n\x1A\n\xFF\xFE".b
      FileUtils.mkdir_p(File.join(dir, "public"))
      File.binwrite(File.join(dir, "public", "icon.png"), bytes)
      src = File.join(dir, "paths.axum.rb")
      File.write(src, HEAD + <<~'RB')
        file "public/icon.png", as: :icon, binary: true

        get "/icon" do
          send_file(file_path(:icon), content_type: "image/png")
        end
      RB
      files = AxumDsl::Emit.files(AxumDsl.read(src), src)
      assert_equal bytes, files["public/icon.png"].b, "the copy is byte for byte"
      assert_includes files["src/main.rs"], "let _text = std::fs::read(&path)", "the startup check reads bytes"
      File.write(src, HEAD + %(file "public/icon.png", as: :icon, binary: true\n\nget "/icon" do\n  text(file_text(:icon))\nend\n))
      error = assert_raises(AxumDsl::CompileError) { AxumDsl.read(src) }
      assert_includes error.message, "is a `binary: true` file"
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

  # A page behind a cookie must not be stored by a shared cache. `use_layer :private_cache` appends
  # Cache-Control: private, no-cache and Vary: Cookie to every response; it is emitted outside the
  # middleware that can answer a request itself (csrf, fetch_metadata, rate_limit) and inside trace.
  def test_private_cache_appends_its_headers_to_every_response
    files = compile_files(<<~RB)
      use_layer :private_cache
      use_layer :fetch_metadata
      use_layer :rate_limit, per: 60, burst: 3

      get "/" do
        text("ok")
      end
    RB
    main = files["src/main.rs"]
    layer = main.index(".layer(::axum::middleware::from_fn(axum_dsl_private_cache))")
    fetch = main.index(".layer(::axum::middleware::from_fn(axum_dsl_fetch_metadata))")
    rate = main.index(".layer(::axum::middleware::from_fn(axum_dsl_rate_limit))")
    refute_nil layer
    assert_operator fetch, :<, layer, "the cache layer wraps the guard, so its refusals carry the headers"
    assert_operator rate, :<, layer, "the cache layer wraps the limiter, so a 429 carries the headers"
    assert_includes main,
                    'headers.append(::axum::http::header::CACHE_CONTROL, ' \
                    '::axum::http::HeaderValue::from_static("private, no-cache"));'
    assert_includes main,
                    'headers.append(::axum::http::header::VARY, ::axum::http::HeaderValue::from_static("Cookie"));'
    refute_includes files["Cargo.toml"], "tower-http", "the cache layer needs no tower-http feature"
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

  # AX14: named filters stay router layers, and routes opt out with `skip:`. The emitted layer compares the
  # request's method and URI path with the skipping routes (a capture is matched by segment).
  def test_a_named_before_filter_is_one_layer_and_skips_by_method_and_path
    main = compile(<<~RB)
      setting :secret_key, env: "SECRET_KEY_BASE"
      cookies secret: :secret_key

      params :Room do
        field :id, :string, in: :path
      end

      before :authenticate do
        return redirect("/login") if cookie(:who).nil?
        "continue"
      end

      before do
        content_type(:json)
        "ok"
      end

      get "/session/new", skip: [:authenticate] do
        text("sign in")
      end

      get "/rooms/:id", params: :Room, skip: [:authenticate] do
        text("room")
      end
    RB
    assert_includes main, "fn before_1_skip(method: &::axum::http::Method, path: &str) -> bool {"
    assert_includes main,
                    %q{*method == ::axum::http::Method::GET && axum_dsl_skip_match("/session/new", path)}
    assert_includes main, %q{axum_dsl_skip_match("/rooms/{id}", path)}, "a capture keeps the axum path shape"
    assert_includes main, "if before_1_skip(request.method(), request.uri().path()) {"
    assert_includes main, "        return next.run(request).await;"
    refute_includes main, "before_2_skip", "an anonymous filter has no skip list"
    assert_includes main, ".layer(axum::middleware::from_fn(before_1))"
    assert_includes main, ".layer(axum::middleware::from_fn(before_2))", "a named filter is still a router layer"
    assert_includes main, "fn axum_dsl_skip_match(pattern: &str, path: &str) -> bool {"
    assert_includes main, %q(if segment.starts_with("{*")), "the matcher understands an axum wildcard"
  end

  # A filter whose skip list is one entry emits a bare condition as the function's body. It used to be
  # parenthesized, and `(cond)` as an expression body is rustc's `unused_parens`, which every generated crate
  # denies (`RUSTFLAGS=-Dwarnings`), so a filter whose only skip was the implicit /cable entry did not compile.
  # No earlier test had exactly one entry: two routes join with `||`, and a serve_file contributes GET and HEAD.
  def test_a_single_skip_condition_is_not_parenthesized
    main = compile(<<~RB)
      before :authenticate do
        "continue"
      end

      get "/one", skip: [:authenticate] do
        text("one")
      end
    RB
    assert_includes main,
                    "-> bool {\n    *method == ::axum::http::Method::GET && axum_dsl_skip_match(\"/one\", path)\n",
                    "one entry is the function's whole body, unparenthesized"
    refute_includes main, "-> bool {\n    (", "a parenthesized body is unused_parens, denied by -D warnings"
  end

  # A segment with a literal prefix and a capture (`@:message_id`) is an axum route as written, and the skip
  # matcher reads its prefix: it used to compare `@{message_id}` with the concrete part as a literal, which never
  # matched, so a cached route of that shape found no ticket and answered 500.
  def test_a_prefixed_capture_segment_keeps_its_route_and_is_matched_by_prefix
    main = compile(<<~RB)
      setting :secret_key, env: "SECRET_KEY_BASE"
      cookies secret: :secret_key

      params :At do
        field :id, :i64, in: :path
        field :message_id, :i64, in: :path
      end

      before :authenticate do
        return redirect("/login") if cookie(:who).nil?
        "continue"
      end

      get "/rooms/:id/@:message_id", params: :At, skip: [:authenticate] do
        text("at")
      end
    RB
    assert_includes main, %q{.route("/rooms/{id}/@{message_id}"}
    assert_includes main, %q{axum_dsl_skip_match("/rooms/{id}/@{message_id}", path)}
    assert_includes main, "if let (Some(open), Some(close)) = (segment.find('{'), segment.rfind('}')) {"
    assert_includes main, "!part.starts_with(prefix) || !part.ends_with(suffix)"
  end

  # The required form: after the named filter, the current reads at its non-nil type with no `nil?`/`||` in
  # the route; the filter itself still reads the nil-able type so its guard can work.
  def test_a_required_current_reads_non_nil_after_its_filter
    main = compile(<<~RB)
      current :who, returns: :string?, required: :authenticate do
        request_ip
      end

      before :authenticate do
        return redirect("/login") if current(:who).nil?
        "continue"
      end

      get "/me" do
        text(current(:who))
      end
    RB
    assert_includes main, %q{axum_dsl_require_current(__currents.who.get_or_try_init(}
    assert_includes main, %q{).await?.clone(), "who")?}, "the route gets the value, not an Option"
    assert_includes main, "fn axum_dsl_require_current<T>(value: Option<T>, name: &str) -> Result<T, String> {"
    assert_includes main, %q{get_or_try_init(|| axum_dsl_current_who(&__headers, __peer, &__currents)).await?.clone()},
                    "the filter still reads the nil-able value"
    refute_match(/match __currents\.who[^\n]*None =>/, main, "the route does not unwrap or match the Option")
  end

  # The refusal half of the required form: a route that skips the establishing filter may not read the
  # current at the non-nil type, because nothing proves the filter ran.
  def test_a_route_that_skips_the_required_filter_cannot_read_it
    message = refusal(<<~RB)
      current :who, returns: :string?, required: :authenticate do
        request_ip
      end

      before :authenticate do
        return redirect("/login") if current(:who).nil?
        "continue"
      end

      get "/me", skip: [:authenticate] do
        text(current(:who))
      end
    RB
    assert_includes message, "but this route skips `:authenticate`"
    assert_includes message, "drop `:authenticate` from the route's `skip:`"
  end

  MISSING_DECLS = <<~RB
    database :sqlite, path: "paths.sqlite3"
    record :Flags do
      field :id, :i64
      field :title, :string
    end
    query :flags_for, args: { id: :i64 }, returns: :Flags?, sql: "SELECT id, title FROM flags WHERE id = :id"
  RB

  # `returns: :Record, missing:` is a non-nil current: the reader has the record type (a `.field` read needs no `|| raise`),
  # an empty body fails the request as `raise` does, and the failure is not cached (the cell is only set on Ok).
  def test_a_missing_current_reads_non_nil_and_fails_like_raise
    main = compile(MISSING_DECLS + <<~RB)
      current :flags, returns: :Flags, reader: :current_flags, missing: "the flags were not read back" do
        flags_for(id: 1)
      end

      get "/t" do
        text(current_flags.title + current(:flags).title)
      end

      get "/r" do
        flags = flags_for(id: 2) || raise("the flags were not read back")
        text(flags.title)
      end
    RB
    assert_includes main, "::tokio::sync::OnceCell<Flags>,", "the cell holds the record, not an Option"
    assert_includes main, %q{None => Err("the flags were not read back".to_string()),}, "the same Err(String) a raise returns"
    assert_includes main, "Some(__row) => Ok(__row),"
    assert_includes main, %q{return Err("the flags were not read back".to_string())}, "raise compiles to the same Err"
  end

  def test_a_nil_able_current_is_unchanged_beside_missing
    main = compile(MISSING_DECLS + <<~RB)
      current :flags, returns: :Flags? do
        flags_for(id: 1)
      end

      get "/t" do
        flags = current(:flags) || raise("gone")
        text(flags.title)
      end
    RB
    assert_includes main, "::tokio::sync::OnceCell<Option<Flags>>,"
    refute_includes main, "Some(__row) => Ok(__row)"
  end

  def test_missing_is_refused_where_it_does_not_apply
    body = "get \"/t\" do\n  text(current(:flags).to_s)\nend\n"
    message = refusal(MISSING_DECLS + "current :flags, returns: :Flags do\n  flags_for(id: 1)\nend\n" + body)
    assert_includes message, "returns: :Flags?"
    assert_includes message, "returns: :Flags, missing: \"message\""
    message = refusal(MISSING_DECLS + "current :flags, returns: :Flags?, missing: \"gone\" do\n  flags_for(id: 1)\nend\n" + body)
    assert_includes message, "`missing:` is for a current that returns a record without `?`"
    message = refusal(MISSING_DECLS + "current :flags, returns: :Flags, missing: \"gone\", required: :authenticate do\n  flags_for(id: 1)\nend\n" + body)
    assert_includes message, "says both `missing:` and `required:`"
    message = refusal(MISSING_DECLS + "current :flags, returns: :Flags, missing: \"gone\" do\n  flags_for(id: 1)\nend\n" +
                      "cable \"/cable\", authenticate_with: :flags do\n  channel \"HeartbeatChannel\"\nend\n")
    assert_includes message, "needs a nil-able current"
  end

  # The skip is matched at run time, so it may not overlap a route that does not skip the filter.
  def test_a_skip_that_could_match_a_non_skipping_route_is_refused
    message = refusal(<<~RB)
      params :Room do
        field :id, :string, in: :path
      end

      before :authenticate do
        "continue"
      end

      get "/rooms/:id", params: :Room, skip: [:authenticate] do
        text("room")
      end

      get "/rooms/me" do
        text("me")
      end
    RB
    assert_includes message, "also matches `get /rooms/me`, which does not skip it"
  end

  # A guard in a filter makes its body fallible. The closure must yield a Response: `return Ok(redirect)`
  # answers the request, and a plain final value is dropped before `next.run` supplies the response.
  def test_a_fallible_before_filter_that_continues_yields_a_response
    main = compile(<<~RB)
      current :who, returns: :string? do
        request_ip
      end

      before :authenticate do
        return redirect("/session/new") if current(:who).nil?
        "continue"
      end

      get "/me" do
        text("ok")
      end
    RB
    assert_includes main, "let response = match (async || -> Result<::axum::response::Response, String> {"
    assert_includes main, "return Ok({ let mut __redirect = "
    assert_includes main, "Ok(next.run(request).await)"
    assert_includes main, "Ok(response) => response,"
    assert_includes main, "Err(message) => return error_response(&message),", "an error answers immediately, before the filter's own status/headers"
    refute_includes main, "Result<(), String> {", "a continuing filter yields the response it passes on"
  end

  # AX14 follow-up: a static mount is covered by a named filter's layer too, so the mount takes `skip:`.
  # The emitted skip covers GET of the prefix and of its subtree, which keeps /assets public.
  def test_a_static_mount_skips_a_named_filter_for_the_prefix_and_its_subtree
    files = compile_files(<<~RB, extra: { "public/app.css" => "body { color: red }" })
      before :authenticate do
        "continue"
      end

      static "/assets", dir: "public", skip: [:authenticate]

      get "/" do
        text("ok")
      end
    RB
    main = files["src/main.rs"]
    assert_includes main, %q{*method == ::axum::http::Method::GET && axum_dsl_skip_match("/assets", path)}
    assert_includes main, %q{*method == ::axum::http::Method::GET && axum_dsl_skip_match("/assets/{*path}", path)}
    assert_includes main, "if before_1_skip(request.method(), request.uri().path()) {"
    assert_includes main, %q{.nest_service("/assets", ::tower_http::services::ServeDir::new("public")},
                    "the mount is still emitted"
  end

  # A mount at "/" is axum's fallback, so its skip would cover every GET path and step a named filter
  # aside for every GET route. That cannot be scoped, so it is refused; without skip the mount is fine.
  def test_a_root_static_mount_cannot_take_a_skip
    message = refusal(<<~RB, extra: { "public/app.css" => "body { color: red }" })
      before :authenticate do
        "continue"
      end

      static "/", dir: "public", skip: [:authenticate]

      get "/" do
        text("ok")
      end
    RB
    assert_includes message, "`static \"/\"` is axum's fallback for every GET path"
    assert_includes message, "cannot be scoped"

    files = compile_files(<<~RB, extra: { "public/app.css" => "body { color: red }" })
      static "/", dir: "public"

      get "/" do
        text("ok")
      end
    RB
    assert_includes files["src/main.rs"], '.fallback_service(::tower_http::services::ServeDir::new("public")'

    # An empty skip is not a skip: the refusal is for a non-empty `skip:` only.
    files = compile_files(<<~RB, extra: { "public/app.css" => "body { color: red }" })
      before :authenticate do
        "continue"
      end

      static "/", dir: "public", skip: []

      get "/" do
        text("ok")
      end
    RB
    assert_includes files["src/main.rs"], '.fallback_service(::tower_http::services::ServeDir::new("public")'
    refute_includes files["src/main.rs"], "before_1_skip", "an empty skip is no skip"
  end

  # use_layer :private_cache, except: ["/assets"] leaves the two headers off the files of a declared
  # static mount (the safe default is on everywhere else). It emits a prefix list matched exactly or at a
  # `/` boundary, computes the path before next.run, and needs no tower-http feature of its own.
  def test_private_cache_except_names_a_mount_and_emits_the_prefix_matcher
    files = compile_files(<<~RB, extra: { "public/x.css" => "x" })
      static "/assets", dir: "public"
      use_layer :private_cache, except: ["/assets"]

      get "/" do
        text("ok")
      end
    RB
    main = files["src/main.rs"]
    assert_includes main, 'const AXUM_DSL_PRIVATE_CACHE_EXCEPT: &[&str] = &["/assets"];'
    assert_includes main, "fn axum_dsl_private_cache_exempt(path: &str) -> bool {"
    assert_includes main, "path.strip_prefix(*prefix).map_or(false, |rest| rest.starts_with('/'))"
    assert_includes main, "let exempt = axum_dsl_private_cache_exempt(request.uri().path());"
    assert_includes main, "if !exempt {"
    assert_includes main, ".layer(::axum::middleware::from_fn(axum_dsl_private_cache))"
    assert_includes main,
                    'headers.append(::axum::http::header::CACHE_CONTROL, ' \
                    '::axum::http::HeaderValue::from_static("private, no-cache"));'
    assert_includes main,
                    'headers.append(::axum::http::header::VARY, ::axum::http::HeaderValue::from_static("Cookie"));'
    assert_includes files["Cargo.toml"], 'tower-http = { version = "0.6", features = ["fs"] }',
                    "the static mount still needs fs, and the layer adds no feature"
    refute_includes files["Cargo.toml"], "compression-gzip"

    plain = compile("use_layer :private_cache\n\nget \"/\" do\n  text(\"ok\")\nend\n")
    refute_includes plain, "AXUM_DSL_PRIVATE_CACHE_EXCEPT", "without except: the emitted runtime is unchanged"

    # A path inside a mount is a declared public path too, at a segment boundary.
    nested = compile_files(%(static "/assets", dir: "public"\nuse_layer :private_cache, except: ["/assets/css"]\n\nget "/" do\n  text("ok")\nend\n),
                           extra: { "public/css/app.css" => "x" })["src/main.rs"]
    assert_includes nested, 'const AXUM_DSL_PRIVATE_CACHE_EXCEPT: &[&str] = &["/assets/css"];'
  end
end
