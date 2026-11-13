# frozen_string_literal: true

# Models, associations, scopes and named expressions (docs/database.md, "Models"): declarations that fill the
# model registry (Db::Models) and emit nothing. Each case compiles a small DSL string; the refusals are also pinned
# by test/refusals/model_*.rb and expr_*.rb. No cargo and no HTTP.
#
#   ruby -Ilib test/test_db_models.rb
require "minitest/autorun"
require "tmpdir"
require "axum_dsl"

class TestDbModels < Minitest::Test
  HEAD = <<~RB
    server "models", version: "0.1.0"
    set :port, 8080
  RB

  ROUTE = %(get "/" do\n  text("hi")\nend\n)

  TABLES = <<~RB
    table :users do
      field :id, :i64
      field :name, :string
      field :bio, :string, optional: true
    end

    table :rooms do
      field :id, :i64
      field :name, :string, optional: true
      field :type, :string
      field :creator_id, :i64
    end

    table :memberships do
      field :id, :i64
      field :room_id, :i64
      field :user_id, :i64
    end

    table :messages do
      field :id, :i64
      field :room_id, :i64
    end

    table :boosts do
      field :id, :i64
      field :message_id, :i64
    end

    table :action_text_rich_texts do
      field :id, :i64
      field :record_type, :string
      field :record_id, :i64
    end

    table :active_storage_attachments do
      field :id, :i64
      field :record_type, :string
      field :record_id, :i64
    end

    table :message_search_index do
      field :rowid, :i64
      field :body, :string
    end
  RB

  EXPRS = <<~RB
    expr :now, type: :string, sql: "strftime('%Y-%m-%d %H:%M:%f', 'now')"
    expr :user_title, of: :t, type: :string,
         sql: "CASE WHEN COALESCE({t}.bio, '') = '' THEN {t}.name ELSE {t}.name || ' – ' || {t}.bio END"
  RB

  # The models the Room example needs besides Room itself.
  OTHERS = <<~RB
    model :User, table: :users do
    end

    model :Membership, table: :memberships do
      belongs_to :user, model: :User
      belongs_to :room, model: :Room
    end

    model :Message, table: :messages do
      has_many :boosts, dependent: :delete_all
      has_many :rich_texts, table: :action_text_rich_texts, as: :record, dependent: :delete_all
      has_many :attachments, table: :active_storage_attachments, as: :record, dependent: :delete_all
      has_one :search_row, table: :message_search_index, foreign_key: :rowid, dependent: :delete_all
      belongs_to :room, model: :Room
    end
  RB

  ROOM = <<~RB
    model :Room, table: :rooms do
      has_many :memberships, dependent: :delete_all
      has_many :messages, dependent: :destroy
      has_many :users, through: :memberships
      has_many :rich_texts, table: :action_text_rich_texts, as: :record, dependent: :delete_all
      has_one :search_row, table: :message_search_index, foreign_key: :rowid, dependent: :delete_all
      belongs_to :creator, model: :User, foreign_key: :creator_id
      scope :directs, -> { where(type: "Rooms::Direct") }
      scope :visible_to, ->(uid) { joins(:memberships).where(memberships: { user_id: uid }) }
    end
  RB

  EXAMPLE = TABLES + EXPRS + OTHERS + ROOM

  # Exprs in models and in a concern: User and Room each have a `title`, and User includes the concern Timestamps (Room has no updated_at).
  OWNED = <<~RB
    database :sqlite, path: "x.db"

    table :users do
      field :id, :i64
      field :name, :string
      field :updated_at, :string
    end

    table :rooms do
      field :id, :i64
      field :name, :string
      field :creator_id, :i64
    end

    record :Titles do
      field :own, :string
      field :theirs, :string
      field :stamp, :i64
    end

    concern :Timestamps do
      expr :updated_ms, type: :i64, sql: "CAST(strftime('%s', {t}.updated_at) AS INTEGER)"
    end

    model :User, table: :users do
      include :Timestamps
      expr :title, type: :string, sql: "UPPER({t}.name)"
    end

    model :Room, table: :rooms do
      belongs_to :creator, model: :User, foreign_key: :creator_id
      expr :title, type: :string, sql: "LOWER({t}.name)"
      query :titles, args: {}, returns: list(:Titles) do
        joins(:creator).select(own: expr(:title), theirs: expr(:title, :creator), stamp: expr(:updated_ms, :creator))
      end
    end

    get "/titles" do
      json(titles)
    end
  RB

  NODES = %(table :nodes do\n  field :id, :i64\n  field :parent_id, :i64\nend\n)

  def read(source)
    Dir.mktmpdir("models") do |dir|
      file = File.join(dir, "models.axum.rb")
      File.write(file, HEAD + source)
      yield AxumDsl.read(file), file
    end
  end

  def registry(source)
    read(source + ROUTE) do |ir, _file|
      yield AxumDsl::Db::Models.from_ir(ir["models"], ir["exprs"], AxumDsl::Db::Schema.from_ir(ir["tables"]))
    end
  end

  def rust(source)
    read(source) { |ir, file| AxumDsl::Emit.files(ir, file)["src/main.rs"] }
  end

  # Each compile runs in its own temporary directory, and the generated Rust names the source file, so that
  # directory is taken out before comparing.
  def assert_same_rust(with, without)
    a = with.gsub(%r{/[^"\s]*/models\.axum\.rb}, "models.axum.rb").lines
    b = without.gsub(%r{/[^"\s]*/models\.axum\.rb}, "models.axum.rb").lines
    clip = ->(lines) { lines.first(8).map { |l| l.strip[0, 300] } }
    assert_equal [], clip.call(a - b) + ["--- without models only ---"] + clip.call(b - a), "Rust differs with models" unless a == b
  end

  # Compiles the source, expects the refusal to say `text`, and answers the error (its #suggestions).
  def refused(source, text)
    Dir.mktmpdir("models") do |dir|
      file = File.join(dir, "models.axum.rb")
      File.write(file, HEAD + source + ROUTE)
      error = assert_raises(AxumDsl::CompileError) { AxumDsl.read(file) }
      assert_includes error.message, text
      error
    end
  end

  def test_models_and_exprs_emit_no_rust
    assert_same_rust rust(EXAMPLE + ROUTE), rust(TABLES + ROUTE)
    assert_same_rust rust(TABLES + ROUTE), rust(ROUTE)
  end

  def test_a_file_without_models_has_empty_registries
    read(ROUTE) do |ir, _file|
      assert_equal [], ir["models"]
      assert_equal [], ir["exprs"]
    end
  end

  def test_the_forms_a_model_has_always_had_still_work
    read(%(model "Room" do\nend\nmodel "Account::Bot" do\nend\n) + ROUTE) do |ir, _file|
      assert_equal ["Room", "Account::Bot"], ir["models"].map { |m| m["name"] }
      assert_equal [nil, nil], ir["models"].map { |m| m["table"] }
    end
  end

  def test_a_model_may_be_named_by_a_symbol_and_owns_a_table
    registry(TABLES + %(model :Room, table: :rooms do\nend\nmodel :Bot do\nend\n)) do |models|
      assert_equal %w[Room Bot], models.model_names
      assert_equal "rooms", models.table(:Room)
      assert_nil models.table("Bot")
      assert models.model?("Room")
      refute models.model?("Nope")
    end
  end

  def test_the_model_for_a_table_is_the_one_that_owns_it
    registry(TABLES + OTHERS + ROOM) do |models|
      assert_equal "Message", models.model_for_table("messages")
      assert_nil models.model_for_table("boosts")
    end
    registry(TABLES + %(model :A, table: :rooms do\nend\nmodel :B, table: :rooms do\nend\n)) do |models|
      assert_nil models.model_for_table("rooms")
    end
  end

  def test_has_many_resolves_its_table_model_and_foreign_key
    registry(EXAMPLE) do |models|
      assert_equal({ name: "memberships", kind: :has_many, target_table: "memberships", target_model: "Membership",
                     foreign_key: "room_id", owner_key: "id", discriminator: nil, through: nil, source: nil, dependent: :delete_all, conditions: nil },
                   models.association("Room", "memberships"))
      assert_equal "Message", models.association(:Room, :messages)[:target_model]
      assert_equal :destroy, models.association(:Room, :messages)[:dependent]
    end
  end

  def test_a_polymorphic_has_many_carries_its_discriminator
    registry(EXAMPLE) do |models|
      rich = models.association("Room", "rich_texts")
      assert_equal "action_text_rich_texts", rich[:target_table]
      assert_nil rich[:target_model]
      assert_equal "record_id", rich[:foreign_key]
      assert_equal({ "record_type" => "Room" }, rich[:discriminator])
    end
  end

  def test_has_one_takes_its_foreign_key_from_the_keyword
    registry(EXAMPLE) do |models|
      row = models.association("Room", "search_row")
      assert_equal [:has_one, "message_search_index", "rowid", "id", :delete_all], row.values_at(:kind, :target_table, :foreign_key, :owner_key, :dependent)
    end
  end

  def test_belongs_to_holds_the_foreign_key_on_its_own_table
    registry(EXAMPLE) do |models|
      creator = models.association("Room", "creator")
      assert_equal [:belongs_to, "users", "User", "creator_id", "creator_id", nil],
                   creator.values_at(:kind, :target_table, :target_model, :foreign_key, :owner_key, :dependent)
      assert_equal "user_id", models.association("Membership", "user")[:foreign_key]
    end
  end

  def test_the_foreign_key_of_a_has_many_is_the_owners_name_underscored
    source = TABLES + %(table :order_lines do\n  field :id, :i64\n  field :line_item_id, :i64\nend\n) +
             %(model :LineItem, table: :messages do\n  has_many :order_lines\nend\n)
    registry(source) { |models| assert_equal "line_item_id", models.association("LineItem", "order_lines")[:foreign_key] }
  end

  def test_through_goes_to_the_source_of_the_far_association
    registry(EXAMPLE) do |models|
      users = models.association("Room", "users")
      assert_equal [:has_many, "users", "User", "memberships", "user", nil, nil],
                   users.values_at(:kind, :target_table, :target_model, :through, :source, :foreign_key, :dependent)
    end
  end

  def test_associations_come_in_declaration_order_and_unknown_ones_are_nil
    registry(EXAMPLE) do |models|
      assert_equal %w[memberships messages users rich_texts search_row creator], models.associations("Room").map { |a| a[:name] }
      assert_nil models.association("Room", "nope")
      assert_nil models.association("Nope", "messages")
      assert_equal [], models.associations("Nope")
    end
  end

  def test_scopes_keep_their_parameters_and_their_unevaluated_body
    registry(EXAMPLE) do |models|
      directs = models.scope("Room", "directs")
      assert_equal [], directs[:params]
      assert_kind_of Prism::StatementsNode, directs[:body]
      assert_includes directs[:body].slice, 'where(type: "Rooms::Direct")'
      assert_kind_of Integer, directs[:line]
      visible = models.scope(:Room, :visible_to)
      assert_equal ["uid"], visible[:params]
      assert_includes visible[:body].slice, "joins(:memberships)"
      assert_nil models.scope("Room", "nope")
      assert_nil models.scope("Nope", "directs")
    end
  end

  def test_a_scope_may_take_several_parameters
    registry(TABLES + %(model :Room, table: :rooms do\n  scope :between, ->(a, b) { where(id: a) }\nend\n)) do |models|
      assert_equal %w[a b], models.scope("Room", "between")[:params]
    end
  end

  def test_the_route_scope_is_still_a_path_prefix
    assert_equal({ path: [:str, true] }, AxumDsl.sig(:scope, :top)[:kw])
    assert_equal %i[column lambda], AxumDsl.sig(:scope, :model)[:pos]
    assert_nil AxumDsl.sig(:scope, :controller)
  end

  def test_expressions_are_looked_up_by_name
    registry(EXPRS) do |models|
      assert_equal({ name: "now", type: "string", sql: "strftime('%Y-%m-%d %H:%M:%f', 'now')", of: nil }, models.expr("now"))
      title = models.expr(:user_title)
      assert_equal %w[string t], title.values_at(:type, :of)
      assert_includes title[:sql], "{t}.name"
      assert_nil models.expr("nope")
    end
  end

  def test_a_model_expr_is_its_own_and_a_concern_expr_follows_the_include
    registry(OWNED) do |models|
      assert_equal ["UPPER({t}.name)", "User"], models.expr(:title, model: "User").values_at(:sql, :model)
      assert_equal ["LOWER({t}.name)", "Room"], models.expr(:title, model: "Room").values_at(:sql, :model)
      assert_nil models.expr(:title)
      assert_equal "Timestamps", models.expr(:updated_ms, model: "User")[:concern]
      assert_nil models.expr(:updated_ms, model: "Room") # Room does not include Timestamps
      assert_equal %w[title updated_ms], models.expr_names(model: "User")
      assert_equal %w[title], models.expr_names(model: "Room")
    end
    read(OWNED + ROUTE) do |ir, _file|
      assert_equal [["updated_ms", nil, "Timestamps"], ["title", "User", nil], ["title", "Room", nil]], ir["exprs"].map { |e| [e["name"], e["model"], e["concern"]] }
      assert_equal %w[t t t], ir["exprs"].map { |e| e["of"] } # `{t}` implies `of: :t`
    end
  end

  def test_a_relation_reads_the_exprs_of_its_model_and_of_the_joined_model
    read(OWNED + ROUTE) do |ir, _file|
      sql = ir["queries"].first["sql"]
      assert_includes sql, "LOWER(rooms.name) AS own"
      assert_includes sql, "UPPER(users.name) AS theirs"
      assert_includes sql, "CAST(strftime('%s', users.updated_at) AS INTEGER) AS stamp"
    end
  end

  def test_an_expr_a_relation_asks_for_must_belong_to_its_model_or_be_shared
    refused(OWNED.sub("expr(:title, :creator)", "expr(:updated_ms)"), "no `expr :updated_ms` is declared (declared for Room: title); `updated_ms` is in concern `Timestamps`; add `include :Timestamps` to `Room`")
    refused(OWNED.sub("own: expr(:title)", "own: expr(:nope)"), "no `expr :nope` is declared")
  end

  def test_a_model_expr_may_not_reuse_a_shared_name_or_a_name_twice
    refused(OWNED + %(expr :title, type: :string, sql: "1"\n), "expr `title` of model User has the name of an expr of the top level")
    stamps = %(concern :Stamps do\n  expr :title, type: :string, sql: "1"\nend\n)
    refused(OWNED.sub("  include :Timestamps\n", "  include :Timestamps\n  include :Stamps\n") + stamps, "has the name of an expr of concern Stamps")
    refused(OWNED + %(model :Dup, table: :rooms do\n  expr :a, type: :string, sql: "1"\n  expr :a, type: :string, sql: "2"\nend\n), "duplicate expr `a`")
    refused(OWNED + %(concern :User do\n  expr :b, type: :string, sql: "1"\nend\n), "concern \"User\" is also the name of a model")
  end

  def test_an_include_names_a_concern_the_table_fits_once_and_without_a_clash
    refused(OWNED.sub("include :Timestamps", "include :Timestmps"), "model \"User\" includes concern \"Timestmps\", which is not declared (declared: Timestamps)")
    refused(OWNED.sub("belongs_to :creator", "include :Timestamps\n  belongs_to :creator"),
            "model \"Room\" includes concern \"Timestamps\", but its expr `updated_ms` reads `{t}.updated_at` and table `rooms` has no column `updated_at`")
    refused(OWNED.sub("include :Timestamps", "include :Timestamps\n  include :Timestamps"), "model \"User\" includes concern \"Timestamps\" twice")
    other = %(concern :Other do\n  expr :updated_ms, type: :i64, sql: "{t}.updated_at"\nend\n)
    refused(OWNED.sub("include :Timestamps", "include :Timestamps\n  include :Other") + other,
            "model \"User\" includes concerns \"Timestamps\" and \"Other\", which both have an expr `updated_ms`")
    read(OWNED + ROUTE) { |ir, _file| assert_equal ["Timestamps"], ir["models"].find { |m| m["name"] == "User" }["includes"] }
  end

  def test_the_destroy_plan_follows_the_dependent_declarations_in_order
    registry(EXAMPLE) do |models|
      body = { table: "action_text_rich_texts", fk: "record_id", discriminator: { "record_type" => "Message" }, mode: :delete_all, dependents: [] }
      messages = { table: "messages", fk: "room_id", discriminator: nil, mode: :destroy,
                   dependents: [{ table: "boosts", fk: "message_id", discriminator: nil, mode: :delete_all, dependents: [] },
                                body, body.merge(table: "active_storage_attachments"),
                                { table: "message_search_index", fk: "rowid", discriminator: nil, mode: :delete_all, dependents: [] }] }
      assert_equal [{ table: "memberships", fk: "room_id", discriminator: nil, mode: :delete_all, dependents: [] },
                    messages,
                    body.merge(discriminator: { "record_type" => "Room" }),
                    { table: "message_search_index", fk: "rowid", discriminator: nil, mode: :delete_all, dependents: [] }],
                   models.destroy_plan("Room")
    end
  end

  # The tree test/test_db_rel.rb hands Db::Rel.destroy for the room delete: messages (with what hangs on them) first.
  def test_the_destroy_plan_is_the_tree_the_relation_layer_takes
    room = %(model :Room, table: :rooms do\n  has_many :messages, dependent: :destroy\n  has_many :memberships, dependent: :delete_all\nend\n)
    registry(TABLES + OTHERS + room) do |models|
      body = { table: "action_text_rich_texts", fk: "record_id", discriminator: { "record_type" => "Message" }, mode: :delete_all, dependents: [] }
      attachments = body.merge(table: "active_storage_attachments")
      messages = { table: "messages", fk: "room_id", discriminator: nil, mode: :destroy,
                   dependents: [{ table: "boosts", fk: "message_id", discriminator: nil, mode: :delete_all, dependents: [] },
                                body, attachments,
                                { table: "message_search_index", fk: "rowid", discriminator: nil, mode: :delete_all, dependents: [] }] }
      memberships = { table: "memberships", fk: "room_id", discriminator: nil, mode: :delete_all, dependents: [] }
      assert_equal [messages, memberships], models.destroy_plan("Room")
    end
  end

  def test_a_model_without_dependents_has_an_empty_plan
    registry(EXAMPLE) { |models| assert_equal [], models.destroy_plan("User") }
  end

  def test_the_plan_of_an_unknown_model_is_refused
    registry(EXAMPLE) do |models|
      error = assert_raises(AxumDsl::Db::Models::Unresolved) { models.destroy_plan("Nope") }
      assert_includes error.message, 'no model "Nope" is declared'
    end
  end

  def test_a_dependent_cycle_is_refused
    refused(NODES + %(model :Node, table: :nodes do\n  has_many :children, table: :nodes, foreign_key: :parent_id, dependent: :destroy\nend\n),
            'model "Node" has_many :children, dependent: :destroy, goes round in a circle (Node -> Node)')
    pair = %(table :cats do\n  field :id, :i64\n  field :dog_id, :i64\nend\ntable :dogs do\n  field :id, :i64\n  field :cat_id, :i64\nend\n) +
           %(model :Cat, table: :cats do\n  has_many :dogs, table: :dogs, foreign_key: :cat_id, dependent: :destroy\nend\n) +
           %(model :Dog, table: :dogs do\n  has_many :cats, table: :cats, foreign_key: :dog_id, dependent: :destroy\nend\n)
    refused(pair, "(Cat -> Dog -> Cat)")
  end

  def test_a_delete_all_cycle_is_not_one
    registry(NODES + %(model :Node, table: :nodes do\n  has_many :children, table: :nodes, foreign_key: :parent_id, dependent: :delete_all\nend\n)) do |models|
      assert_equal [{ table: "nodes", fk: "parent_id", discriminator: nil, mode: :delete_all, dependents: [] }], models.destroy_plan("Node")
    end
  end

  def test_a_model_table_that_is_not_declared_is_refused_with_the_nearest
    error = refused(TABLES + %(model :Room, table: :roms do\nend\n), 'model "Room": table `roms` is not declared (declared: users, rooms')
    assert_equal ["rooms"], error.suggestions
  end

  def test_a_model_with_associations_or_scopes_must_name_its_table
    refused(TABLES + %(model :Room do\n  has_many :messages\nend\n), 'model "Room" declares associations or scopes, so it names its table')
    refused(TABLES + %(model :Room do\n  scope :a, -> { where(id: 1) }\nend\n), 'model "Room" declares associations or scopes')
  end

  def test_an_association_declared_twice_is_refused
    refused(TABLES + %(model :Room, table: :rooms do\n  has_many :messages\n  has_many :messages\nend\n), 'model "Room" has_many :messages is declared twice')
  end

  def test_a_missing_target_table_model_or_column_is_refused
    refused(TABLES + %(model :Room, table: :rooms do\n  has_many :nothings\nend\n), 'model "Room" has_many :nothings: table `nothings` is not declared')
    error = refused(TABLES + %(model :Room, table: :rooms do\n  has_many :things, table: :mesages\nend\n), "table `mesages` is not declared")
    assert_equal ["messages"], error.suggestions
    refused(TABLES + %(model :Room, table: :rooms do\n  belongs_to :creator, model: :Usr\nend\n), "`model: :Usr` is not a declared model (declared: Room)")
    refused(TABLES + %(model :Room, table: :rooms do\n  has_many :boosts\nend\n), 'model "Room" has_many :boosts: table `boosts` has no column `room_id`')
    refused(TABLES + %(model :Room, table: :rooms do\n  belongs_to :owner, table: :users\nend\n), 'model "Room" belongs_to :owner: table `rooms` has no column `owner_id`')
    error = refused(TABLES + %(model :Room, table: :rooms do\n  has_many :messages, foreign_key: :roomid\nend\n), "table `messages` has no column `roomid`")
    assert_equal ["room_id"], error.suggestions
  end

  def test_a_has_one_and_a_belongs_to_must_name_their_target
    refused(TABLES + %(model :Room, table: :rooms do\n  has_one :search_row\nend\n), 'model "Room" has_one :search_row: name the target with `model:` or `table:`')
    refused(TABLES + %(model :Room, table: :rooms do\n  belongs_to :creator\nend\n), 'model "Room" belongs_to :creator: name the target with `model:` or `table:`')
  end

  def test_a_model_without_a_table_cannot_be_a_target
    refused(TABLES + %(model :Bot do\nend\nmodel :Room, table: :rooms do\n  belongs_to :creator, model: :Bot\nend\n), 'model "Bot" names no table')
  end

  def test_a_polymorphic_child_needs_its_type_and_id_columns
    refused(TABLES + %(model :Room, table: :rooms do\n  has_many :things, table: :messages, as: :record\nend\n),
            'model "Room" has_many :things: table `messages` has no column `record_type`')
    refused(TABLES + %(table :marks do\n  field :id, :i64\n  field :record_type, :string\nend\nmodel :Room, table: :rooms do\n  has_many :marks, as: :record\nend\n),
            "table `marks` has no column `record_id`")
    refused(TABLES + %(model :Room, table: :rooms do\n  has_many :messages, as: :record, foreign_key: :room_id\nend\n), "`as:` already names the foreign key (`record_id`)")
  end

  def test_through_needs_an_association_of_the_same_model_and_a_source
    refused(TABLES + OTHERS + %(model :Room, table: :rooms do\n  has_many :memberships\n  has_many :users, through: :members\nend\n),
            "`through: :members` is not an association of the model (declared: memberships, users)")
    refused(TABLES + %(model :User, table: :users do\nend\nmodel :Membership, table: :memberships do\nend\n) +
            %(model :Room, table: :rooms do\n  has_many :memberships\n  has_many :users, through: :memberships\nend\n),
            'model "Membership", which `through: :memberships` goes through, has no association :users or :user')
    refused(TABLES + %(model :Room, table: :rooms do\n  has_many :memberships\n  has_many :users, through: :memberships\nend\n),
            "`through: :memberships` reaches table `memberships`, which no `model` owns")
    refused(TABLES + OTHERS + %(model :Room, table: :rooms do\n  has_many :memberships\n  has_many :users, through: :memberships\n  has_many :people, through: :users\nend\n),
            "`through: :users` is itself a through association")
  end

  def test_through_takes_nothing_of_its_own
    ["table: :users", "model: :User", "foreign_key: :user_id", "as: :user", "dependent: :destroy"].each do |kw|
      refused(TABLES + %(model :Room, table: :rooms do\n  has_many :users, through: :memberships, #{kw}\nend\n),
              "`through:` takes its table and keys from the associations it goes through, so `#{kw.split(':').first}:` does not apply")
    end
  end

  def test_dependent_through_and_as_are_for_has_many_and_has_one
    ["dependent: :destroy", "through: :users", "as: :record"].each do |kw|
      refused(TABLES + %(model :Room, table: :rooms do\n  belongs_to :creator, model: :User, #{kw}\nend\n),
              "`#{kw.split(':').first}:` applies to has_many and has_one, not belongs_to")
    end
  end

  def test_a_dependent_is_destroy_or_delete_all
    refused(TABLES + %(model :Room, table: :rooms do\n  has_many :messages, dependent: :nullify\nend\n), "`:nullify` is not one of :destroy :delete_all")
  end

  def test_an_unknown_association_keyword_is_refused_with_the_allowed_ones
    refused(TABLES + %(model :Room, table: :rooms do\n  has_many :messages, class_name: "Message"\nend\n), "unknown keyword `class_name:` for `has_many`")
  end

  def test_associations_are_only_for_a_model
    refused(%(has_many :messages\n), "`has_many` is not allowed in the top level (valid there:")
  end

  def test_a_scope_is_a_lambda
    refused(TABLES + %(model :Room, table: :rooms do\n  scope :directs do\n    where(type: "x")\n  end\nend\n),
            "`scope` takes its body as a lambda, not a block: write `scope :name, -> { where(...) }`")
    refused(TABLES + %(model :Room, table: :rooms do\n  scope :directs, proc { where(id: 1) }\nend\n), "expected a lambda such as `-> { where(...) }`")
    refused(TABLES + %(model :Room, table: :rooms do\n  scope :directs\nend\n), "`scope` takes 2 positional argument(s), got 1")
    refused(TABLES + %(model :Room, table: :rooms do\n  scope :directs, -> { }\nend\n), 'model "Room" scope :directs has an empty lambda')
  end

  def test_a_scope_lambda_takes_plain_required_names
    ["->(a = 1) { a }", "->(*a) { a }", "->(a:) { a }", "->(&b) { 1 }"].each do |lam|
      refused(TABLES + %(model :Room, table: :rooms do\n  scope :by, #{lam}\nend\n), 'model "Room" scope :by: the parameters of a scope lambda are plain required names')
    end
    refused(TABLES + %(model :Room, table: :rooms do\n  scope :by, -> { _1 }\nend\n), "not `_1` or `it`")
  end

  def test_a_scope_name_is_unique_and_not_an_association_or_an_operation
    refused(TABLES + %(model :Room, table: :rooms do\n  scope :a, -> { 1 }\n  scope :a, -> { 2 }\nend\n), 'model "Room" scope :a is declared twice')
    refused(TABLES + %(model :Room, table: :rooms do\n  has_many :messages\n  scope :messages, -> { 1 }\nend\n), "scope :messages: `messages` is already an association of the model")
    refused(TABLES + %(model :Room, table: :rooms do\n  scope :messages, -> { 1 }\n  has_many :messages\nend\n), "has_many :messages: `messages` is already a scope of the model")
    AxumDsl::Db::Models::OPERATIONS.each do |op|
      refused(TABLES + %(model :Room, table: :rooms do\n  scope :#{op}, -> { 1 }\nend\n), "scope :#{op}: `#{op}` is a relation operation")
    end
  end

  def test_an_expr_needs_a_unique_name_and_a_scalar_type
    refused(EXPRS + %(expr :now, type: :string, sql: "1"\n), "duplicate expr `now`")
    refused(%(expr :n, type: :i32, sql: "1"\n), "`:i32` is not one of :string :i64 :f64 :bool")
    refused(%(expr :n, sql: "1"\n), "`expr` requires `type:`")
    refused(%(expr :n, type: :i64\n), "`expr` requires `sql:`")
  end

  def test_an_expr_template_has_one_table_reference_exactly_when_it_says_of
    refused(%(expr :n, of: :t, type: :i64, sql: "1"\n), "expr `n` says `of: :t`, so its sql writes that table as `{t}` at least once")
    refused(%(expr :n, of: :t, type: :i64, sql: "{u}.id"\n), "expr `n` says `of: :t`, so its sql writes that table as `{t}` at least once")
    refused(%(expr :n, of: :t, type: :i64, sql: "{t}.id + {u}.id"\n), "expr `n` takes one table reference, `{t}`, and its sql also writes `{u}`")
    refused(%(expr :n, type: :i64, sql: "{t}.id"\n), "expr `n` writes `{t}` but has no `of:`; add `of: :t`")
    read(%(expr :n, of: :tbl, type: :i64, sql: "{tbl}.id + {tbl}.rank"\n) + ROUTE) { |ir, _file| assert_equal "tbl", ir["exprs"][0]["of"] }
  end

  def test_an_expr_has_no_placeholder
    refused(%(expr :n, type: :i64, sql: "id = :id"\n), "expr `n` has the placeholder `:id` in its sql")
    refused(%(expr :n, type: :i64, sql: "id = ?"\n), "has the placeholder `?` in its sql")
    read(%(expr :n, type: :string, sql: "':id' || '?' || \\"x:y\\""\n) + ROUTE) { |ir, _file| assert_equal 1, ir["exprs"].size }
  end

  def test_an_unused_model_and_expr_are_not_refused
    read(EXAMPLE + ROUTE) do |ir, _file|
      assert_equal %w[User Membership Message Room], ir["models"].map { |m| m["name"] }
      assert_equal %w[now user_title], ir["exprs"].map { |e| e["name"] }
    end
  end

  def test_a_model_in_a_use_dsl_file_keeps_its_declarations
    Dir.mktmpdir("models") do |dir|
      Dir.mkdir(File.join(dir, "models"))
      File.write(File.join(dir, "models", "room.axum.rb"), %(model table: :rooms do\n  scope :a, -> { where(id: 1) }\nend\n))
      file = File.join(dir, "models.axum.rb")
      File.write(file, HEAD + TABLES + %(use_dsl "models/room.axum.rb"\n) + ROUTE)
      ir = AxumDsl.read(file)
      assert_equal ["Room"], ir["models"].map { |m| m["name"] }
      assert_equal "rooms", ir["models"][0]["table"]
    end
  end
end
