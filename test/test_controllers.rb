# frozen_string_literal: true

# controller blocks: routes, `before :def, only:/except:` filters and defs expanded inline. The behaviour is checked
# by laws over the example's routes (AXUM_CARGO=1); the expansion and the refusals here.
#
#   ruby -Ilib test/test_controllers.rb
require "minitest/autorun"
require "tmpdir"
require "open3"
require "axum_dsl"

class TestControllers < Minitest::Test
  EXAMPLE = File.expand_path("../examples/controllers.axum.rb", __dir__)

  def emit(src)
    Dir.mktmpdir("ctl") do |dir|
      file = File.join(dir, "app.axum.rb")
      File.write(file, src)
      AxumDsl::Emit.files(AxumDsl.read(file), file)["src/main.rs"]
    end
  end

  def refused(src) = assert_raises(AxumDsl::CompileError) { emit(src) }.message

  def read_ir(src)
    Dir.mktmpdir("ctl") do |dir|
      file = File.join(dir, "app.axum.rb")
      File.write(file, src)
      AxumDsl.read(file)
    end
  end

  HEAD = <<~RB
    server "ctl", version: "0.1.0"
    params :P do
      field :id, :i64, min: 1, in: :path
    end
  RB

  def ctl(inner) = HEAD + "controller \"Things\" do\n#{inner}\nend\n"

  def test_a_filter_runs_first_in_the_actions_it_names
    main = emit(File.read(EXAMPLE))
    show = main[/async fn route_2\b.*?\n}\n/m]
    index = main[/async fn route_1\b.*?\n}\n/m]
    assert_includes show, "{ // def ensure_admin (before filter), app.axum.rb:" if show.include?("app.axum.rb")
    assert_match(/def ensure_admin \(before filter\)/, show)
    refute_match(/ensure_admin/, index, "except: [:index]")
    assert_match(/let id = \{ if !helper_known\(id\)/, show, "a def used as a value is a block whose last expression is the value")
  end

  def test_a_defs_locals_stay_inside_it
    src = ctl(<<~RB)
      get "/a/:id", params: :P do
        x = twice
        "\#{x}"
      end
      def twice
        y = params[:id] * 2
        y
      end
    RB
    assert_match(/let x = \{ let y = ck_mul_i64\(id, 2, .*?\)\?;\ny \};/, emit(src))
  end

  def test_parameters_are_bound_from_the_arguments
    src = HEAD + "def add_one(n)\n  n + 1\nend\nget \"/a/:id\", params: :P do\n  \"\#{add_one(params[:id])}\"\nend\n"
    assert_match(/\{ let n = id;\nck_add_i64\(n, 1, /, emit(src))
  end

  # Ruby reads a local without consuming it: a string passed to a def is still the caller's after the call.
  def test_a_local_passed_to_a_def_stays_readable
    src = HEAD + "def greet(s)\n  \"hello \#{s}\"\nend\nget \"/a/:id\", params: :P do\n  word = \"you \#{params[:id]}\"\n  line = greet(word)\n  \"\#{line} \#{word}\"\nend\n"
    assert_match(/\{ let s = word\.clone\(\);/, emit(src))
  end

  def test_refusals
    assert_includes refused(HEAD + "get \"/a/:id\", params: :P, action: :show do\n  \"x\"\nend\n"), "`action:` names a route in a controller"
    assert_includes refused(ctl("before :nope\nget \"/a/:id\", params: :P do\n  \"x\"\nend")), "`before :nope` names no def"
    assert_includes refused(ctl("before :g, only: [:edit]\nget \"/a/:id\", params: :P, action: :show do\n  \"x\"\nend\ndef g\n  1\nend")),
                    "Things has no action `edit`"
    assert_includes refused(ctl("before :g do\n  \"continue\"\nend\nget \"/a/:id\", params: :P do\n  \"x\"\nend")), "a do ... end filter is a top-level one"
    assert_includes refused(HEAD + "before :g\nget \"/a/:id\", params: :P do\n  \"x\"\nend\n"), "needs a do ... end block"
    assert_includes refused(ctl("before :g, only: [:a], except: [:a]\nget \"/a/:id\", params: :P, action: :a do\n  \"x\"\nend\ndef g\n  1\nend")),
                    "give one"
    assert_includes refused(ctl("get \"/a/:id\", params: :P do\n  \"\#{f}\"\nend\ndef f\n  g\nend\ndef g\n  f\nend")), "a def is expanded inline, so it cannot recurse"
    assert_includes refused(ctl("get \"/a/:id\", params: :P do\n  \"\#{f(1)}\"\nend\ndef f\n  1\nend")), "def `f` takes 0 arguments (), got 1"
    assert_includes refused(ctl("def f\n  1\nend\ndef f\n  2\nend\nget \"/a/:id\", params: :P do\n  \"\#{f}\"\nend")), "duplicate def `f`"
    assert_includes refused(ctl("get \"/a/:id\", params: :P, action: :a do\n  \"x\"\nend\nget \"/b/:id\", params: :P, action: :a do\n  \"y\"\nend")),
                    "duplicate action `a`"
    assert_includes refused(HEAD + "controller \"things\" do\nend\n"), "a controller is named like a Rails one"
    # A def is a method, not a block: it does not see the caller's locals.
    assert_match(/unsupported call `z`/, refused(ctl("get \"/a/:id\", params: :P do\n  z = 1\n  \"\#{f}\"\nend\ndef f\n  z + 1\nend")))
    helper = "helper :f, args: [:i64], returns: :i64 do |x|\n  x\nend\ndef f\n  1\nend\nget \"/a/:id\", params: :P do\n  \"\#{f(params[:id])}\"\nend\n"
    assert_includes refused(HEAD + helper), "def `f` has the name of a helper"
  end

  # --- controller values (RB2) -------------------------------------------------------------------------

  def test_a_filter_provides_a_value_the_action_reads
    src = ctl(<<~RB)
      before :set_thing, only: [:show], provides: :thing
      get "/a/:id", params: :P, action: :show do
        text(thing)
      end
      def set_thing
        thing = params[:id]
        return halt(404, "") if thing == 0
        thing
      end
    RB
    main = emit(src)
    assert_match(/let thing = \{.*?let thing = id;.*?\};/m, main)
  end

  def test_a_later_filter_reads_an_earlier_provided_value
    src = ctl(<<~RB)
      before :set_thing, only: [:show], provides: :thing
      before :checked_thing, only: [:show], provides: :checked
      get "/a/:id", params: :P, action: :show do
        text(checked)
      end
      def set_thing
        params[:id]
      end
      def checked_thing
        thing + 1
      end
    RB
    main = emit(src)
    assert_includes main, "ck_add_i64(thing, 1"
  end

  def test_a_guard_only_filter_reads_an_earlier_provided_value
    src = ctl(<<~RB)
      before :set_thing, only: [:show], provides: :thing
      before :ensure_thing, only: [:show]
      get "/a/:id", params: :P, action: :show do
        text(thing)
      end
      def set_thing
        params[:id]
      end
      def ensure_thing
        return head(403) unless thing == 1
      end
    RB
    main = emit(src)
    refute_includes main, "unsupported call"
    assert_match(/def ensure_thing \(before filter\).*?thing == 1/m, main)
  end

  def test_a_guard_only_filter_does_not_see_the_actions_locals
    src = ctl(<<~RB)
      before :ensure_thing, only: [:show]
      get "/a/:id", params: :P, action: :show do
        z = 1
        text(z)
      end
      def ensure_thing
        return head(403) unless z == 1
      end
    RB
    assert_match(/unsupported call `z`/, refused(src))
  end

  def test_a_guard_reading_a_name_the_action_is_not_provided_is_refused
    msg = refused(guard_unprovided_src)
    assert_includes msg, "`before :ensure_thing` reads `thing`, which `before :set_thing` provides, but not to the action `show`"
  end

  def guard_unprovided_src
    ctl(<<~RB)
      before :set_thing, only: [:index], provides: :thing
      before :ensure_thing, only: [:show]
      get "/a/:id", params: :P, action: :index do
        text(thing)
      end
      get "/b/:id", params: :P, action: :show do
        "x"
      end
      def set_thing
        params[:id]
      end
      def ensure_thing
        return head(403) unless thing == 1
      end
    RB
  end

  TX_HEAD = HEAD + <<~RB
    database :sqlite, path: "x.db"
    record :User do
      field :id, :i64
    end
    query :find_user, args: { id: :i64 }, returns: :User?, sql: "SELECT id FROM users WHERE id = :id"
    execute :add_note, args: { author: :i64, body: :string }, sql: "INSERT INTO notes (author, body) VALUES (:author, :body)"
    query :count_notes, args: {}, returns: :i64, sql: "SELECT COUNT(*) FROM notes"
  RB

  TX_BLOCK = "transaction do\n    add_note(author: %s, body: \"x\")\n    count_notes\n  end"

  # The transaction closure only: the rest of the route differs between a filter and a local, by design. The
  # temporary directory is taken out of generated paths, as the other same-Rust tests do.
  def tx_closure(main)
    main.gsub(%r{/[^"\s]*/app\.axum\.rb}, "app.axum.rb").lines.grep(/db_tx\(/).map(&:strip)
  end

  def test_a_provided_value_in_a_transaction_compiles_as_a_plain_local_does
    provided = TX_HEAD + <<~RB
      controller "Things" do
        before :set_user, only: [:create], provides: :user
        post "/a/:id", params: :P, action: :create do
          n = #{TX_BLOCK % "user.id"}
          text(n)
        end
        def set_user
          find_user(id: params[:id]) || raise("gone")
        end
      end
    RB
    local = TX_HEAD + <<~RB
      post "/a/:id", params: :P do
        user = find_user(id: params[:id]) || raise("gone")
        n = #{TX_BLOCK % "user.id"}
        text(n)
      end
    RB
    got = tx_closure(emit(provided))
    refute_empty got
    assert_equal tx_closure(emit(local)), got
  end

  def test_a_call_in_a_transaction_is_still_refused_with_a_provided_value_in_scope
    src = TX_HEAD + <<~RB
      controller "Things" do
        before :set_user, only: [:create], provides: :user
        post "/a/:id", params: :P, action: :create do
          n = #{TX_BLOCK % "other"}
          text(n)
        end
        def set_user
          find_user(id: params[:id]) || raise("gone")
        end
        def other
          1
        end
      end
    RB
    assert_includes refused(src), "argument `author` calls `other` inside the `transaction` block"
  end

  def test_an_action_def_is_the_route_body
    src = ctl(<<~RB)
      get "/a/:id", params: :P, action: :show
      def show
        text(params[:id])
      end
    RB
    main = emit(src)
    assert_match(/async fn route_1/, main)
    refute_includes main, "unsupported call"
  end

  def test_a_route_without_a_block_or_action_is_refused
    msg = refused(ctl(%(get "/a/:id", params: :P\n)))
    assert_includes msg, "a route needs a do ... end block, or `action:`"
  end

  def test_an_action_naming_a_missing_def_is_refused
    msg = refused(ctl(%(get "/a/:id", params: :P, action: :show\n)))
    assert_includes msg, "Things has no def `show`"
  end

  def test_provides_on_a_top_level_filter_is_refused
    msg = refused(HEAD + %(before :g, provides: :x do\n  "x"\nend\nget "/a/:id", params: :P do\n  "x"\nend\n))
    assert_includes msg, "`provides:` is for a controller's `before :name`"
  end

  def test_a_providing_filter_must_end_in_a_value
    msg = refused(ctl(<<~RB))
      before :set_thing, only: [:show], provides: :thing
      get "/a/:id", params: :P, action: :show do
        text(thing)
      end
      def set_thing
        return halt(404, "")
      end
    RB
    assert_includes msg, "used as a value but ends in `return` or `raise`"
  end

  def test_two_filters_providing_one_name_are_refused
    msg = refused(ctl(<<~RB))
      before :one, only: [:show], provides: :thing
      before :two, only: [:show], provides: :thing
      get "/a/:id", params: :P, action: :show do
        text(thing)
      end
      def one
        1
      end
      def two
        2
      end
    RB
    assert_includes msg, "another filter on this action already provides it"
  end

  def test_an_action_def_takes_no_parameters
    msg = refused(ctl(<<~RB))
      get "/a/:id", params: :P, action: :show
      def show(x)
        text(x)
      end
    RB
    assert_includes msg, "an action def takes no parameters"
  end

  # --- routes in a file (RB3) --------------------------------------------------------------------------

  def test_a_route_in_a_file_names_its_controller_and_action
    src = HEAD + <<~RB
      controller "Things" do
        before :set_thing, only: [:show], provides: :thing
        def set_thing
          params[:id]
        end
        def show
          text(thing)
        end
      end
      get "/a/:id", params: :P, controller: "Things", action: :show
    RB
    main = emit(src)
    assert_match(/let thing = \{.*?id.*?\};/m, main)
    assert_match(/async fn route_1/, main)
  end

  def test_an_unknown_controller_on_a_route_is_refused
    msg = refused(HEAD + %(get "/a/:id", params: :P, controller: "Nope", action: :show\n))
    assert_includes msg, "no controller `Nope` is declared"
  end

  def test_controller_on_a_route_inside_a_controller_is_refused
    msg = refused(ctl(%(get "/a/:id", params: :P, controller: "Things", action: :show do\n  "x"\nend\n)))
    assert_includes msg, "`controller:` is for a route outside a controller"
  end

  def test_a_route_outside_a_controller_without_controller_is_refused
    msg = refused(HEAD + %(get "/a/:id", params: :P, action: :show\n))
    assert_includes msg, "`action:` names a route in a controller; this route is in none"
  end

  # --- resources and scope (RB3) -----------------------------------------------------------------------

  def test_resources_generates_the_rails_routes_and_path_helpers
    src = HEAD + <<~RB
      controller "Things" do
        def index
          text(things_path)
        end
        def show
          text(thing_path(params[:id]))
        end
        def update
          text(thing_url(params[:id]))
        end
      end
      resources :things, only: %i[index show update], params: :P
    RB
    ir = read_ir(src)
    assert_equal [%w[get /things], %w[get /things/{id}], %w[patch /things/{id}]],
                 ir["routes"].map { |r| [r["method"], r["path"]] }
    assert_equal ["put"], ir["routes"].last["also"]
    main = emit(src)
    assert_includes main, '"/things"'
    assert_includes main, 'format!("/things/{}", '
    assert_includes main, "axum_dsl_request_base_url"
  end

  def test_scope_prefixes_the_routes_and_their_path_helpers
    src = HEAD + <<~RB
      controller "Things" do
        def show
          text(thing_path(params[:id]))
        end
      end
      scope path: "admin" do
        resources :things, only: [:show], params: :P
      end
    RB
    assert_equal "/admin/things/{id}", read_ir(src)["routes"].last["path"]
    assert_includes emit(src), 'format!("/admin/things/{}", '
  end

  def test_resources_refuses_a_member_route_without_params
    src = HEAD + "controller \"Things\" do\n  def show\n    text(\"x\")\n  end\nend\n" \
                "resources :things, only: [:show]\n"
    assert_includes refused(src), "whose path captures `:id`"
  end

  # --- a resource's :id is derived from its model's table (RR6) -------------------------------------------

  def derive_src(id_type: "i64", params: nil, declared: nil)
    group = declared ? "params :P do\n  field :id, :#{declared}, in: :path\nend\n" : ""
    <<~RB
      server "ctl", version: "0.1.0"
      table :things do
        field :id, :#{id_type}
      end
      model :Thing, table: :things do
      end
      #{group}controller "Things" do
        def show
          text("x")
        end
      end
      resources :things, only: [:show]#{declared ? ", params: :P" : ""}
    RB
  end

  def test_a_resource_member_derives_id_from_its_models_table
    ir = read_ir(derive_src)
    assert_equal "ThingsMemberPath", ir["routes"].last["params"]
    f = ir["params"].find { |p| p["name"] == "ThingsMemberPath" }["fields"].first
    assert_equal %w[id i64 path], [f["name"], f["type"], f["in"]]
    assert_equal({ "from" => "things.id", "via" => "resources :things", "resource" => "things", "model" => "Thing" },
                 f["derived"].except("at"))
    assert_match(/:\d+\z/, f["derived"]["at"])
    assert_includes emit(derive_src), "struct ThingsMemberPath"
  end

  def test_a_derived_string_key_is_a_string_path_field
    f = read_ir(derive_src(id_type: "string"))["params"].first["fields"].first
    assert_equal "string", f["type"]
  end

  def test_a_declared_path_field_that_repeats_the_derivation_is_noticed
    AxumDsl::Notify.reset!
    read_ir(derive_src(declared: "i64"))
    note = AxumDsl::Notify.notes.find { |n| n.code == "N-PATH-PARAM-DERIVED" }
    assert note, "expected N-PATH-PARAM-DERIVED"
    assert_includes note.message, "resources :things"
  end

  def test_a_declared_path_field_that_contradicts_the_derivation_is_refused
    msg = refused(derive_src(declared: "string"))
    assert_includes msg, "is declared :string, but `resources :things` derives `:id` as :i64 (things.id, model Thing"
  end

  def test_a_resource_without_a_model_for_its_table_still_needs_params
    msg = refused(HEAD + "table :things do\n  field :id, :i64\nend\ncontroller \"Things\" do\n  def show\n    text(\"x\")\n  end\nend\n" \
                         "resources :things, only: [:show]\n")
    assert_includes msg, "no model with `table: :things`"
  end

  def test_a_resources_group_with_query_fields_gets_the_derived_id_in_front
    src = derive_src.sub("resources :things, only: [:show]", "params :Q do\n  field :page, :i64, in: :query, optional: true\nend\nresources :things, only: [:show], params: :Q")
    assert_equal %w[id page], read_ir(src)["params"].first["fields"].map { |f| f["name"] }
  end

  def test_a_resource_names_its_model_with_model
    src = derive_src.sub("resources :things, only: [:show]", "resources :stuff, only: [:show], controller: \"Things\", model: :Thing")
    f = read_ir(src)["params"].first["fields"].first
    assert_equal %w[id i64 path], [f["name"], f["type"], f["in"]]
    assert_equal({ "from" => "things.id", "via" => "resources :stuff", "resource" => "stuff", "model" => "Thing" }, f["derived"].except("at"))
  end

  def test_resources_refuses_a_model_that_is_not_declared
    msg = refused(derive_src.sub("resources :things, only: [:show]", "resources :things, only: [:show], model: :Nope"))
    assert_includes msg, "names model `Nope`, which is not declared (declared: Thing)"
  end

  def test_resources_takes_params_and_description_by_action
    src = <<~RB
      server "ctl", version: "0.1.0"
      table :things do
        field :id, :i64
      end
      model :Thing, table: :things do
      end
      params :Form do
        field :name, :string, in: :form
      end
      controller "Things" do
        def create
          text("x")
        end
        def edit
          text("x")
        end
      end
      resources :things, only: %i[create edit], params: { create: :Form }, description: { create: "Make", edit: "Change" }
    RB
    routes = read_ir(src)["routes"]
    assert_equal [["post", "/things", "Form", "Make"], ["get", "/things/{id}/edit", "ThingsMemberPath", "Change"]],
                 routes.map { |r| [r["method"], r["path"], r["params"], r["description"]] }
  end

  def test_resources_refuses_a_by_action_hash_for_an_action_it_does_not_route
    msg = refused(derive_src.sub("resources :things, only: [:show]", "resources :things, only: [:show], params: { edit: :P }"))
    assert_includes msg, "`params:` names `edit`, which the resource does not route (it routes show)"
  end

  def test_resources_refuses_a_by_action_hash_key_that_is_not_an_action
    msg = refused(derive_src.sub("resources :things, only: [:show]", "resources :things, only: [:show], description: { shw: \"x\" }"))
    assert_includes msg, "`shw` is not one of the seven resource actions"
  end

  def test_resources_refuses_an_unknown_action

    msg = refused(HEAD + "controller \"Things\" do\nend\nresources :things, only: [:bogus]\n")
    assert_includes msg, "not one of the seven"
  end

  def test_resources_refuses_nesting
    msg = refused(HEAD + "controller \"Things\" do\nend\nresources :things do\n  resources :boosts\nend\n")
    assert_includes msg, "nested `resources` is not implemented"
  end

  def test_a_path_helper_takes_the_route_captures
    src = HEAD + <<~RB
      controller "Things" do
        def show
          text(thing_path)
        end
      end
      resources :things, only: [:show], params: :P
    RB
    assert_includes refused(src), "`thing_path` takes 1 argument (id)"
  end

  def test_scope_refuses_an_optional_segment
    assert_includes refused(HEAD + "scope path: \"x?y\" do\nend\n"), "optional segment"
  end

  # The example's laws: index is open, show is guarded (7 is refused), set_thing answers 404 past 9, else the value.
  def test_cargo_runs_the_controller_laws
    skip "set AXUM_CARGO=1 to build and run the laws" unless ENV["AXUM_CARGO"]

    Dir.mktmpdir("ctl-cargo") do |dir|
      out = File.join(dir, "crate")
      ir = AxumDsl.read(EXAMPLE)
      AxumDsl::Emit.files(ir, EXAMPLE).each do |path, text|
        FileUtils.mkdir_p(File.dirname(File.join(out, path)))
        File.write(File.join(out, path), text)
      end
      AxumDsl::Lockfile.pin(out, AxumDsl::Emit::VETTED_LOCK)
      env = { "RUSTFLAGS" => "-Dwarnings", "CARGO_TARGET_DIR" => File.join(Dir.tmpdir, "axum_dsl_laws_target") }
      o, st = Open3.capture2e(env, "cargo", "test", "--quiet", "--locked", chdir: out)
      assert st.success?, o
      assert_match(/test result: ok\. 2 passed/, o)
    end
  end
end
