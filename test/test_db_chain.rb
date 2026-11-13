# frozen_string_literal: true

# `query`/`execute` written as a relation (docs/database.md, "Queries as relations"): each supported operation pinned
# by the exact SQL it renders (lib/axum_dsl/db/chain.rb), the seam proved by compiling the same app with `sql:` text
# and comparing the Rust, and the declaration order kept. The refusals are pinned by test/refusals/chain_*.rb.
# No cargo and no HTTP.
#
#   ruby -Ilib test/test_db_chain.rb
require "minitest/autorun"
require "tmpdir"
require "axum_dsl"

class TestDbChain < Minitest::Test
  NOW = "strftime('%Y-%m-%d %H:%M:%f', 'now')"

  HEAD = <<~RB
    server "chain", version: "0.1.0"
    set :port, 8080
    database :sqlite, path: "x.db"
  RB

  TABLES = <<~RB
    table :users do
      field :id, :i64
      field :name, :string
    end

    table :rooms do
      field :id, :i64
      field :name, :string, optional: true
      field :kind, :string
      field :archived, :bool
      field :created_at, :string
      field :updated_at, :string
    end

    table :memberships do
      field :id, :i64
      field :room_id, :i64
      field :user_id, :i64
      field :created_at, :string
      field :updated_at, :string
    end

    table :attachments do
      field :id, :i64
      field :record_type, :string
      field :record_id, :i64
    end
  RB

  EXPRS = <<~RB
    expr :now, type: :string, sql: "strftime('%Y-%m-%d %H:%M:%f', 'now')"
    expr :room_title, of: :t, type: :string, sql: "COALESCE({t}.name, 'room')"
    expr :user_label, of: :u, type: :string, sql: "UPPER({u}.name)"
    expr :archived_flag, of: :t, type: :bool, sql: "{t}.archived = 1"
    expr :owned_by, of: :t, type: :bool, args: { who: :i64 }, sql: "{t}.id = :who"
    expr :either, type: :bool, args: { a: :i64, b: :string }, sql: "(:a = 1 OR :b = 'x')"
  RB

  OTHERS = <<~RB
    model :User, table: :users do
    end

    model :Membership, table: :memberships do
      belongs_to :user, model: :User
      belongs_to :room, model: :Room
    end
  RB

  ROOM = <<~RB
    has_many :memberships
    has_many :users, through: :memberships
    has_many :attachments, table: :attachments, as: :record
    scope :directs, -> { where(kind: "direct") }
    scope :visible_to, ->(uid) { joins(:memberships).where(memberships: { user_id: uid }) }
    scope :direct_visible_to, ->(uid) { directs.visible_to(uid) }
  RB

  RECORDS = {
    id: "record :RoomId do\n  field :id, :i64\nend\n",
    name: "record :RoomName do\n  field :id, :i64\n  field :name, :string\nend\n",
    name_reversed: "record :RoomName do\n  field :name, :string\n  field :id, :i64\nend\n",
    full: "record :RoomFull do\n  field :id, :i64\n  field :name, :string, optional: true\n  field :kind, :string\n" \
          "  field :archived, :bool\n  field :created_at, :string\n  field :updated_at, :string\nend\n",
    title: "record :RoomTitle do\n  field :id, :i64\n  field :title, :string\nend\n",
    who: "record :RoomWho do\n  field :id, :i64\n  field :who, :string\nend\n",
    mine: "record :RoomMine do\n  field :id, :i64\n  field :mine, :bool\nend\n",
    label: "record :RoomLabel do\n  field :label, :string\nend\n",
    flag_int: "record :RoomFlagInt do\n  field :id, :i64\n  field :flag, :i64\nend\n",
    flag_opt: "record :RoomFlagOpt do\n  field :id, :i64\n  field :flag, :i64, optional: true\nend\n",
    flag_bool: "record :RoomFlagBool do\n  field :id, :i64\n  field :flag, :bool\nend\n",
    lits: "record :RoomLits do\n  field :id, :i64\n  field :tag, :string\n  field :n, :i64\n  field :yes, :bool\n  field :no, :bool\nend\n"
  }.freeze

  MEMBERS = "FROM rooms JOIN memberships ON memberships.room_id = rooms.id"
  USERS = "#{MEMBERS} JOIN users ON users.id = memberships.user_id".freeze

  def source(statements, records: "", routes: "")
    "#{HEAD}#{TABLES}#{EXPRS}#{records}#{OTHERS}model :Room, table: :rooms do\n#{ROOM}#{statements}end\n#{routes}"
  end

  def read(src)
    Dir.mktmpdir("chain") do |dir|
      file = File.join(dir, "chain.axum.rb")
      File.write(file, src)
      yield AxumDsl.read(file), file
    end
  end

  def rust(src)
    read(src) { |ir, file| AxumDsl::Emit.files(ir, file)["src/main.rs"] }
  end

  # Each compile runs in its own temporary directory, and the generated Rust names the source file, so that
  # directory is taken out before comparing.
  def assert_same_rust(with, without)
    a = with.gsub(%r{/[^"\s]*/chain\.axum\.rb}, "chain.axum.rb").lines
    b = without.gsub(%r{/[^"\s]*/chain\.axum\.rb}, "chain.axum.rb").lines
    clip = ->(lines) { lines.first(8).map { |l| l.strip[0, 300] } }
    assert_equal [], clip.call(a - b) + ["--- the sql: spelling only ---"] + clip.call(b - a), "Rust differs between the spellings" unless a == b
  end

  # The route that calls a statement, derived from its declaration so every case is one line.
  def call_for(decl)
    name = decl[/(?:query|execute) :(\w+)/, 1]
    vals = decl[/args: \{(.*?)\}/, 1].to_s.scan(/(\w+): :(\w+)/).map { |n, t| "#{n}: #{t == 'string' ? '"a"' : 1}" }
    call = vals.empty? ? name : "#{name}(#{vals.join(', ')})"
    decl.match?(/returns: (list\(:|:[A-Z])/) ? "json(#{call})" : "#{call}.to_s"
  end

  # The SQL a single statement renders to.
  def sql_of(decl, record: nil)
    src = source("#{decl}\n", records: record ? RECORDS.fetch(record) : "", routes: %(get "/x" do\n  #{call_for(decl)}\nend\n))
    read(src) { |ir, _file| ir["queries"].first["sql"] }
  end

  def refused(src, text)
    Dir.mktmpdir("chain") do |dir|
      file = File.join(dir, "chain.axum.rb")
      File.write(file, src)
      error = assert_raises(AxumDsl::CompileError) { AxumDsl.read(file) }
      assert_includes error.message, text
      error
    end
  end

  # --- rows ---------------------------------------------------------------------------------------------------------

  def test_every_column_in_schema_order_is_the_default_selection
    assert_equal "SELECT id, name, kind, archived, created_at, updated_at FROM rooms ORDER BY id",
                 sql_of("query :all_rooms, args: {}, returns: list(:RoomFull) do order(:id) end", record: :full)
  end

  def test_an_optional_record_is_the_first_row
    assert_equal "SELECT id, name, kind, archived, created_at, updated_at FROM rooms WHERE id = :id LIMIT 1",
                 sql_of("query :room, args: { id: :i64 }, returns: :RoomFull? do where(id: arg(:id)) end", record: :full)
  end

  def test_order_and_limit
    assert_equal "SELECT id FROM rooms ORDER BY id DESC LIMIT :n",
                 sql_of("query :recent, args: { n: :i64 }, returns: list(:RoomId) do order(id: :desc).limit(arg(:n)).select(:id) end", record: :id)
    assert_equal "SELECT id FROM rooms ORDER BY kind, id DESC LIMIT 5",
                 sql_of("query :recent, args: {}, returns: list(:RoomId) do order(:kind, id: :desc).limit(5).select(:id) end", record: :id)
    assert_equal "SELECT id FROM rooms ORDER BY id",
                 sql_of("query :recent, args: {}, returns: list(:RoomId) do order(id: :asc).select(:id) end", record: :id)
  end

  def test_order_nocase
    assert_equal "SELECT id FROM rooms ORDER BY name COLLATE NOCASE",
                 sql_of("query :recent, args: {}, returns: list(:RoomId) do order(name: :nocase).select(:id) end", record: :id)
    assert_equal "SELECT id FROM rooms ORDER BY name COLLATE NOCASE, id",
                 sql_of("query :recent, args: {}, returns: list(:RoomId) do order(name: :nocase, id: :asc).select(:id) end", record: :id)
  end

  # --- where ----------------------------------------------------------------------------------------------------------

  def test_where_with_literals
    assert_equal "SELECT id FROM rooms WHERE kind = 'direct' AND name IS NULL AND id = 7 AND archived = 0",
                 sql_of(%(query :ids, args: {}, returns: list(:RoomId) do where(kind: "direct", name: nil).where(id: 7, archived: false).select(:id) end), record: :id)
    assert_equal "SELECT id FROM rooms WHERE kind = 'it''s'",
                 sql_of(%(query :ids, args: {}, returns: list(:RoomId) do where(kind: "it's").select(:id) end), record: :id)
  end

  def test_where_not
    assert_equal "SELECT id FROM rooms WHERE kind <> 'direct' AND name IS NOT NULL AND archived <> 1",
                 sql_of(%(query :ids, args: {}, returns: list(:RoomId) do where_not(kind: "direct", name: nil, archived: true).select(:id) end), record: :id)
  end

  def test_a_list_of_literals_is_in
    assert_equal "SELECT id FROM rooms WHERE id IN (1, 2, 3) AND kind NOT IN ('a', 'b')",
                 sql_of(%(query :ids, args: {}, returns: list(:RoomId) do where(id: [1, 2, 3]).where_not(kind: ["a", "b"]).select(:id) end), record: :id)
  end

  def test_comparisons
    assert_equal "SELECT id FROM rooms WHERE id > 5 AND kind LIKE 'd%'",
                 sql_of(%(query :ids, args: {}, returns: list(:RoomId) do where(gt(:id, 5), like(:kind, "d%")).select(:id) end), record: :id)
    assert_equal "SELECT id FROM rooms WHERE id >= :a AND id < 9 AND id <= 8",
                 sql_of(%(query :ids, args: { a: :i64 }, returns: list(:RoomId) do where(gte(:id, arg(:a)), lt(:id, 9)).where(lte(:id, 8)).select(:id) end), record: :id)
  end

  def test_in_ids_is_a_json_each_of_a_string_argument
    assert_equal "SELECT id FROM rooms WHERE id IN (SELECT value FROM json_each('[' || :ids || ']'))",
                 sql_of(%(query :ids, args: { ids: :string }, returns: list(:RoomId) do where(id: in_ids(arg(:ids))).select(:id) end), record: :id)
    assert_equal "SELECT id FROM rooms WHERE id NOT IN (SELECT value FROM json_each('[' || :ids || ']'))",
                 sql_of(%(query :ids, args: { ids: :string }, returns: list(:RoomId) do where_not(id: in_ids(arg(:ids))).select(:id) end), record: :id)
  end

  # --- joins and scopes -------------------------------------------------------------------------------------------------

  def test_a_join_qualifies_the_columns
    assert_equal "SELECT rooms.id AS id #{MEMBERS} WHERE memberships.user_id = :u",
                 sql_of(%(query :ids, args: { u: :i64 }, returns: list(:RoomId) do joins(:memberships).where(memberships: { user_id: arg(:u) }).select(:id) end), record: :id)
  end

  def test_a_scope_is_inlined_with_its_parameter_bound
    decl = %(query :room_for_user, args: { user_id: :i64, id: :i64 }, returns: :RoomName? do visible_to(arg(:user_id)).where(id: arg(:id)).select(:id, name: coalesce(:name, "")) end)
    assert_equal "SELECT rooms.id AS id, COALESCE(rooms.name, '') AS name #{MEMBERS} WHERE memberships.user_id = :user_id AND rooms.id = :id LIMIT 1",
                 sql_of(decl, record: :name)
  end

  def test_a_scope_may_call_other_scopes
    assert_equal "SELECT rooms.id AS id #{MEMBERS} WHERE rooms.kind = 'direct' AND memberships.user_id = :u",
                 sql_of(%(query :ids, args: { u: :i64 }, returns: list(:RoomId) do direct_visible_to(arg(:u)).select(:id) end), record: :id)
  end

  def test_a_scope_without_parameters
    assert_equal "SELECT id FROM rooms WHERE kind = 'direct'",
                 sql_of(%(query :ids, args: {}, returns: list(:RoomId) do directs.select(:id) end), record: :id)
  end

  def test_a_scope_declared_below_the_statement_that_uses_it
    src = source(%(query :ids, args: {}, returns: list(:RoomId) do late.select(:id) end\nscope :late, -> { where(id: 1) }\n),
                 records: RECORDS.fetch(:id), routes: %(get "/x" do\n  json(ids)\nend\n))
    read(src) { |ir, _file| assert_equal "SELECT id FROM rooms WHERE id = 1", ir["queries"].first["sql"] }
  end

  def test_a_through_association_joins_both_tables
    assert_equal "SELECT rooms.id AS id #{USERS} WHERE users.name = 'x'",
                 sql_of(%(query :ids, args: {}, returns: list(:RoomId) do joins(:users).where(users: { name: "x" }).select(:id) end), record: :id)
  end

  def test_a_polymorphic_association_joins_on_its_discriminator
    assert_equal "SELECT rooms.id AS id FROM rooms JOIN attachments ON attachments.record_id = rooms.id AND attachments.record_type = 'Room'",
                 sql_of(%(query :ids, args: {}, returns: list(:RoomId) do joins(:attachments).select(:id) end), record: :id)
  end

  # --- select ---------------------------------------------------------------------------------------------------------

  def test_select_with_an_expr
    assert_equal "SELECT id, COALESCE(rooms.name, 'room') AS title FROM rooms",
                 sql_of(%(query :titles, args: {}, returns: list(:RoomTitle) do select(:id, title: expr(:room_title)) end), record: :title)
  end

  def test_select_with_an_expr_of_a_joined_table_and_a_joined_column
    assert_equal "SELECT UPPER(users.name) AS label #{USERS}",
                 sql_of(%(query :labels, args: {}, returns: list(:RoomLabel) do joins(:users).select(label: expr(:user_label, :users)) end), record: :label)
    assert_equal "SELECT rooms.id AS id, users.name AS who #{USERS}",
                 sql_of(%(query :whos, args: {}, returns: list(:RoomWho) do joins(:users).select(:id, who: col(:users, :name)) end), record: :who)
  end

  def test_a_record_matches_by_name_in_any_field_order
    assert_equal "SELECT id, COALESCE(name, '') AS name FROM rooms",
                 sql_of(%(query :names, args: {}, returns: list(:RoomName) do select(:id, name: coalesce(:name, "")) end), record: :name_reversed)
  end

  # --- terminals ------------------------------------------------------------------------------------------------------

  def test_count_exists_and_pick
    assert_equal "SELECT COUNT(*) FROM rooms WHERE kind = 'direct'",
                 sql_of(%(query :n, args: {}, returns: :i64 do where(kind: "direct").count end))
    assert_equal "SELECT COUNT(*) FROM rooms", sql_of("query :n, args: {}, returns: :i64 do count end")
    assert_equal "SELECT EXISTS(SELECT 1 FROM rooms WHERE id = :id)",
                 sql_of("query :any, args: { id: :i64 }, returns: :bool do where(id: arg(:id)).exists end")
    assert_equal "SELECT name FROM rooms WHERE id = :id LIMIT 1",
                 sql_of("query :room_name, args: { id: :i64 }, returns: :string? do where(id: arg(:id)).pick(:name) end")
  end

  # An aggregate over the whole relation gives exactly one row, and `coalesce` makes it non-NULL, so the pick is not optional.
  def test_pick_of_a_coalesced_group_concat_is_not_optional
    assert_equal "SELECT COALESCE(group_concat(id), '') FROM rooms WHERE kind = :kind",
                 sql_of(%(query :room_ids, args: { kind: :string }, returns: :string do where(kind: arg(:kind)).pick(coalesce(group_concat(:id), "")) end))
    assert_equal "SELECT COALESCE(group_concat(memberships.user_id), '') FROM rooms JOIN memberships ON memberships.room_id = rooms.id WHERE rooms.id = :id",
                 sql_of(%(query :member_ids, args: { id: :i64 }, returns: :string do joins(:memberships).where(id: arg(:id)).pick(coalesce(group_concat(col(:memberships, :user_id)), "")) end))
  end

  # Not coalesced, the aggregate is NULL over no rows: one row, but an optional value.
  def test_pick_of_a_bare_group_concat_is_optional
    assert_equal "SELECT group_concat(id) FROM rooms",
                 sql_of("query :room_ids, args: {}, returns: :string? do pick(group_concat(:id)) end")
    refuses("query :room_ids, args: {}, returns: :string do pick(group_concat(:id)) end", "`pick` gives :string?, but `returns:` says :string; a pick may find no row or a NULL")
  end

  def test_a_plain_pick_stays_optional_with_a_hint
    refuses("query :room_kind, args: { id: :i64 }, returns: :string do where(id: arg(:id)).pick(:kind) end", "`pick(coalesce(group_concat(:column), \"\"))`")
    refuses("query :room_kind, args: { id: :i64 }, returns: :string do where(id: arg(:id)).pick(expr(:room_title)) end", "a pick may find no row or a NULL")
  end

  def test_a_group_concat_pick_reads_the_whole_relation
    refuses("query :room_ids, args: {}, returns: :string do order(:id).pick(coalesce(group_concat(:id), \"\")) end", "a pick of an aggregate takes a relation without order, limit, offset or distinct")
    refuses("query :room_ids, args: {}, returns: :string do limit(1).pick(coalesce(group_concat(:id), \"\")) end", "a pick of an aggregate takes a relation without order, limit, offset or distinct")
  end

  def test_group_concat_is_only_the_value_of_a_pick
    refused(source("query :room_ids, args: {}, returns: list(:RoomId) do select(:id, ids: group_concat(:id)) end\n", records: RECORDS.fetch(:id), routes: %(get "/x" do\n  json(room_ids)\nend\n)),
            "`group_concat` is an aggregate over the whole relation, so it is only the value of a `pick`")
    refuses("query :room_ids, args: {}, returns: :string do pick(group_concat(:nope)) end", "table `rooms` has no column `nope`")
  end

  def test_touch_delete_update_and_update_all
    assert_equal "UPDATE rooms SET updated_at = #{NOW} WHERE id = :id",
                 sql_of("execute :touch_room, args: { id: :i64 } do where(id: arg(:id)).touch end")
    assert_equal "DELETE FROM rooms WHERE id = :id",
                 sql_of("execute :drop_room, args: { id: :i64 } do where(id: arg(:id)).delete end")
    assert_equal "UPDATE rooms SET name = :name, updated_at = CASE WHEN name IS NOT :name THEN #{NOW} ELSE updated_at END WHERE id = :id",
                 sql_of("execute :rename, args: { id: :i64, name: :string } do where(id: arg(:id)).update(name: arg(:name)) end")
    assert_equal "UPDATE rooms SET name = :name WHERE id = :id",
                 sql_of("execute :rename, args: { id: :i64, name: :string } do where(id: arg(:id)).update_all(name: arg(:name)) end")
    assert_equal "UPDATE rooms SET updated_at = #{NOW} WHERE id = :id",
                 sql_of("execute :stamp, args: { id: :i64 } do where(id: arg(:id)).update(updated_at: expr(:now)) end")
  end

  def test_insert_and_insert_returning
    assert_equal "INSERT INTO rooms (name, kind, created_at, updated_at) VALUES (:name, 'direct', #{NOW}, #{NOW})",
                 sql_of(%(execute :add, args: { name: :string } do insert(name: arg(:name), kind: "direct") end))
    assert_equal "INSERT INTO rooms (name, kind, created_at, updated_at) VALUES (:name, 'direct', #{NOW}, #{NOW}) RETURNING id",
                 sql_of(%(query :add, args: { name: :string }, returns: :i64 do insert(name: arg(:name), kind: "direct", returning: :id) end))
  end

  # --- subrelations and EXISTS ------------------------------------------------------------------------------------------

  def test_a_subrelation_is_in_and_not_in
    assert_equal "UPDATE rooms SET updated_at = #{NOW} WHERE id IN (SELECT room_id FROM memberships WHERE user_id = :u)",
                 sql_of("execute :touch_of, args: { u: :i64 } do where(id: Membership.where(user_id: arg(:u)).select(:room_id)).touch end")
    assert_equal "DELETE FROM rooms WHERE id NOT IN (SELECT room_id FROM memberships)",
                 sql_of("execute :purge, args: {} do where_not(id: Membership.select(:room_id)).delete end")
    assert_equal "DELETE FROM rooms WHERE id IN (SELECT id FROM rooms WHERE kind = 'direct')",
                 sql_of(%(execute :purge, args: {} do where(id: Room.where(kind: "direct").select(:id)).delete end))
    assert_equal "DELETE FROM rooms WHERE id IN (SELECT room_id AS rid FROM memberships ORDER BY id DESC LIMIT 1)",
                 sql_of("execute :purge, args: {} do where(id: Membership.order(id: :desc).limit(1).select(rid: :room_id)).delete end")
  end

  def test_a_subrelation_may_join_and_be_mixed_with_other_conditions
    assert_equal "DELETE FROM rooms WHERE kind = 'a' AND id IN (SELECT memberships.room_id AS room_id FROM memberships JOIN rooms ON rooms.id = memberships.room_id WHERE rooms.kind = 'direct')",
                 sql_of(%(execute :purge, args: {} do where(kind: "a").where(id: Membership.joins(:room).where(rooms: { kind: "direct" }).select(:room_id)).delete end))
  end

  def test_a_comparison_with_a_subrelation_is_a_scalar_subquery
    assert_equal "SELECT id FROM rooms WHERE created_at < (SELECT created_at FROM rooms WHERE id = :id)",
                 sql_of("query :older, args: { id: :i64 }, returns: list(:RoomId) do where(lt(:created_at, Room.where(id: arg(:id)).select(:created_at))).select(:id) end", record: :id)
    assert_equal "SELECT id FROM rooms WHERE id >= (SELECT room_id FROM memberships LIMIT 1)",
                 sql_of("query :older, args: {}, returns: list(:RoomId) do where(gte(:id, Membership.limit(1).select(:room_id))).select(:id) end", record: :id)
  end

  def test_where_exists_correlates_by_the_association_keys
    assert_equal "UPDATE rooms SET updated_at = #{NOW} WHERE EXISTS (SELECT 1 FROM memberships WHERE memberships.room_id = rooms.id AND memberships.user_id = :u)",
                 sql_of("execute :touch_of, args: { u: :i64 } do where_exists(:memberships, user_id: arg(:u)).touch end")
    assert_equal "SELECT COUNT(*) FROM rooms WHERE NOT EXISTS (SELECT 1 FROM memberships WHERE memberships.room_id = rooms.id)",
                 sql_of("query :lonely, args: {}, returns: :i64 do where_not_exists(:memberships).count end")
    assert_equal "SELECT COUNT(*) FROM rooms WHERE EXISTS (SELECT 1 FROM attachments WHERE attachments.record_id = rooms.id AND attachments.record_type = 'Room')",
                 sql_of("query :with_files, args: {}, returns: :i64 do where_exists(:attachments).count end")
  end

  def test_where_exists_takes_the_values_where_takes
    assert_equal "SELECT COUNT(*) FROM rooms WHERE EXISTS (SELECT 1 FROM memberships WHERE memberships.room_id = rooms.id AND memberships.user_id IN (1, 2) AND memberships.id IN (SELECT id FROM users))",
                 sql_of("query :n, args: {}, returns: :i64 do where_exists(:memberships, user_id: [1, 2], id: User.select(:id)).count end")
  end

  def test_subrelation_and_exists_refusals
    decl = ->(chain) { "execute :purge, args: {} do #{chain}.delete end" }
    bad = lambda do |body, text, extra: ""|
      refused(source("#{body}\n", routes: %(get "/x" do\n  #{call_for(body)}\nend\n)) + extra, text)
    end
    error = bad.call(decl.call("where(id: Membershp.select(:room_id))"), "no model `Membershp` is declared")
    assert_includes error.suggestions, "Membership"
    bad.call(decl.call("where(id: Membership.where(user_id: 1))"), "a subrelation of model Membership ends in `select(:column)` or `select(alias: expression)` with one value, not `where`")
    bad.call(decl.call("where(id: Membership.select(:room_id, :user_id))"), "a subrelation of model Membership selects exactly one value (`select(:column)` or `select(alias: expression)`), not 2")
    bad.call(decl.call("where(id: Membership.count)"), "a subrelation of model Membership ends in `select`, so `count` can not be in it")
    bad.call(decl.call("where(id: Membership)"), "a model is followed by a relation ending in `select`")
    bad.call(decl.call("where(id: Loose.select(:id))"), "model `Loose` names no `table:`", extra: "model :Loose do\nend\n")
    bad.call(decl.call("where(id: Membership.where(user_id: arg(:zz)).select(:room_id))"), "`arg(:zz)` is not in `args:`")
    bad.call("scope :mine, -> { where(id: Membership.select(:room_id)) }\n#{decl.call('mine')}", "a subrelation is written in the statement, not in a scope")
    bad.call(decl.call("where_exists(:users)"), "does not support the `through:` association `:users`")
    bad.call(decl.call("where_exists(:nope)"), "has no association `:nope`")
    bad.call(decl.call("where_exists"), "`where_exists` takes an association and optional conditions")
    bad.call(decl.call("where_not_exists(:memberships, nope: 1)"), "table `memberships` has no column `nope`")
  end

  # --- left_joins, or, order by a joined column or an expr --------------------------------------------------------------

  LEFT_MEMBERS = "FROM rooms LEFT OUTER JOIN memberships ON memberships.room_id = rooms.id"
  LEFT_USERS = "#{LEFT_MEMBERS} LEFT OUTER JOIN users ON users.id = memberships.user_id".freeze

  def refuses(body, text)
    refused(source("#{body}\n", routes: %(get "/x" do\n  #{call_for(body)}\nend\n)), text)
  end

  def test_left_joins_is_a_left_outer_join_of_the_same_associations
    assert_equal "SELECT rooms.id AS id #{LEFT_MEMBERS} WHERE memberships.user_id IS NULL",
                 sql_of(%(query :ids, args: {}, returns: list(:RoomId) do left_joins(:memberships).where(memberships: { user_id: nil }).select(:id) end), record: :id)
    assert_equal "SELECT rooms.id AS id #{LEFT_USERS} WHERE users.name = 'x'",
                 sql_of(%(query :ids, args: {}, returns: list(:RoomId) do left_joins(:users).where(users: { name: "x" }).select(:id) end), record: :id)
    assert_equal "SELECT rooms.id AS id FROM rooms LEFT OUTER JOIN attachments ON attachments.record_id = rooms.id AND attachments.record_type = 'Room'",
                 sql_of(%(query :ids, args: {}, returns: list(:RoomId) do left_joins(:attachments).select(:id) end), record: :id)
    assert_equal "SELECT rooms.id AS id #{MEMBERS} LEFT OUTER JOIN attachments ON attachments.record_id = rooms.id AND attachments.record_type = 'Room'",
                 sql_of(%(query :ids, args: {}, returns: list(:RoomId) do joins(:memberships).left_joins(:attachments).select(:id) end), record: :id)
  end

  def test_a_left_joined_column_is_optional_unless_coalesced
    decl = %(query :whos, args: {}, returns: list(:RoomWhos) do left_joins(:users).select(:id, who: col(:users, :name), shown: coalesce(col(:users, :name), "-")) end\n)
    read(source(decl, routes: %(get "/x" do\n  json(whos)\nend\n))) do |ir, _file|
      assert_equal "SELECT rooms.id AS id, users.name AS who, COALESCE(users.name, '-') AS shown #{LEFT_USERS}", ir["queries"].first["sql"]
      assert_equal [["id", nil], ["who", true], ["shown", nil]], ir["records"].first["fields"].map { |f| [f["name"], f["optional"]] }
    end
    refused(source(%(query :whos, args: {}, returns: list(:RoomWho) do left_joins(:users).select(:id, who: col(:users, :name)) end\n),
                   records: RECORDS.fetch(:who), routes: %(get "/x" do\n  json(whos)\nend\n)),
            "field `who` is :string in record `RoomWho`, but the relation gives :string?")
  end

  def test_an_inner_joined_column_stays_required
    decl = %(query :whos, args: {}, returns: list(:RoomWhos) do joins(:users).select(:id, who: col(:users, :name)) end\n)
    read(source(decl, routes: %(get "/x" do\n  json(whos)\nend\n))) do |ir, _file|
      assert_equal [nil, nil], ir["records"].first["fields"].map { |f| f["optional"] }
    end
  end

  def test_left_joins_refusals
    refuses("query :n, args: {}, returns: :i64 do left_joins.count end", "`left_joins` takes association names: `left_joins(:memberships)`")
    refuses("query :n, args: {}, returns: :i64 do left_joins(:memberships).joins(:memberships).count end", "`:memberships` is already joined")
    refuses("query :n, args: {}, returns: :i64 do left_joins(:nope).count end", "has no association `:nope`")
    refuses("query :n, args: {}, returns: :i64 do where(memberships: { user_id: 1 }).count end", "`memberships` is not joined")
    refuses("execute :purge, args: {} do left_joins(:memberships).delete end", "a delete can not have joins")
  end

  def test_or_joins_everything_so_far_with_the_argument
    assert_equal "SELECT id FROM rooms WHERE (kind = 'a') OR (kind = 'b' AND archived = 1)",
                 sql_of(%(query :ids, args: {}, returns: list(:RoomId) do where(kind: "a").or(where(kind: "b", archived: true)).select(:id) end), record: :id)
    assert_equal "SELECT id FROM rooms WHERE (kind = 'a' AND archived = 1) OR (id = :id)",
                 sql_of(%(query :ids, args: { id: :i64 }, returns: list(:RoomId) do where(kind: "a").where(archived: true).or(where(id: arg(:id))).select(:id) end), record: :id)
  end

  def test_what_follows_an_or_is_anded_with_the_whole
    assert_equal "SELECT id FROM rooms WHERE ((kind = 'a') OR (kind = 'b')) AND archived = 0",
                 sql_of(%(query :ids, args: {}, returns: list(:RoomId) do where(kind: "a").or(where(kind: "b")).where(archived: false).select(:id) end), record: :id)
    assert_equal "SELECT COUNT(*) FROM rooms WHERE ((kind = 'a') OR (kind = 'b')) OR (kind = 'c')",
                 sql_of(%(query :n, args: {}, returns: :i64 do where(kind: "a").or(where(kind: "b")).or(where(kind: "c")).count end))
  end

  def test_or_takes_scopes_and_exists_and_works_with_joins_and_writes
    assert_equal "SELECT id FROM rooms WHERE (id = 1) OR (kind = 'direct')",
                 sql_of(%(query :ids, args: {}, returns: list(:RoomId) do where(id: 1).or(directs).select(:id) end), record: :id)
    assert_equal "SELECT id FROM rooms WHERE (kind = 'a') OR (EXISTS (SELECT 1 FROM memberships WHERE memberships.room_id = rooms.id AND memberships.user_id = :u))",
                 sql_of(%(query :ids, args: { u: :i64 }, returns: list(:RoomId) do where(kind: "a").or(where_exists(:memberships, user_id: arg(:u))).select(:id) end), record: :id)
    assert_equal "SELECT rooms.id AS id #{MEMBERS} WHERE (memberships.user_id = :u) OR (rooms.kind = 'direct')",
                 sql_of(%(query :ids, args: { u: :i64 }, returns: list(:RoomId) do joins(:memberships).where(memberships: { user_id: arg(:u) }).or(where(kind: "direct")).select(:id) end), record: :id)
    assert_equal "UPDATE rooms SET updated_at = #{NOW} WHERE (id = 1) OR (id = 2)",
                 sql_of("execute :touch_two, args: {} do where(id: 1).or(where(id: 2)).touch end")
  end

  def test_or_refusals
    only = "`or` takes a chain of `where`, `where_not`, `where_exists`, `where_not_exists` and scopes that only add conditions"
    refuses("execute :purge, args: {} do joins(:memberships).or(where(id: 1)).delete end", "`or` needs a condition before it")
    refuses("execute :purge, args: {} do where(id: 1).or.delete end", "`or` takes one chain of conditions")
    refuses("execute :purge, args: {} do where(id: 1).or(where(id: 2), where(id: 3)).delete end", "`or` takes one chain of conditions")
    refuses("execute :purge, args: {} do where(id: 1).or(joins(:memberships)).delete end", "#{only}; `joins` can not be in it")
    refuses("execute :purge, args: {} do where(id: 1).or(left_joins(:memberships)).delete end", "#{only}; `left_joins` can not be in it")
    refuses("execute :purge, args: {} do where(id: 1).or(where(id: 2).select(:id)).delete end", "#{only}; `select` can not be in it")
    refuses("execute :purge, args: {} do where(id: 1).or(where(id: 2).order(:id)).delete end", "#{only}; `order` can not be in it")
    refuses("execute :purge, args: {} do where(id: 1).or(where(id: 2).limit(1)).delete end", "#{only}; `limit` can not be in it")
    refuses("query :n, args: {}, returns: :i64 do where(id: 1).or(where(id: 2).count).count end", "#{only}; `count` can not be in it")
    refuses("execute :purge, args: {} do where(id: 1).or(where(id: 2).or(where(id: 3))).delete end", "#{only}; `or` can not be in it")
    refuses("execute :purge, args: { u: :i64 } do where(id: 1).or(visible_to(arg(:u))).delete end", "scope `visible_to` does more than add conditions (joins, select, order or limit), so `or` can not take it")
    refuses("execute :purge, args: { u: :i64 } do where(id: 1).or(where(id: arg(:zz))).delete end", "`arg(:zz)` is not in `args:`")
    refuses("execute :purge, args: { u: :i64 } do where(id: 1).or(where(id: 2)).delete end", "`args:` declares `u` but the chain never uses `arg(:u)`")
  end

  def test_order_by_a_joined_column_and_an_expr
    assert_equal "SELECT rooms.id AS id #{USERS} ORDER BY users.name",
                 sql_of(%(query :ids, args: {}, returns: list(:RoomId) do joins(:users).select(:id).order(col(:users, :name)) end), record: :id)
    assert_equal "SELECT rooms.id AS id #{USERS} ORDER BY users.name DESC, rooms.id",
                 sql_of(%(query :ids, args: {}, returns: list(:RoomId) do joins(:users).select(:id).order(col(:users, :name) => :desc, id: :asc) end), record: :id)
    assert_equal "SELECT rooms.id AS id #{USERS} ORDER BY users.name COLLATE NOCASE",
                 sql_of(%(query :ids, args: {}, returns: list(:RoomId) do joins(:users).select(:id).order(col(:users, :name) => :nocase) end), record: :id)
    assert_equal "SELECT id FROM rooms ORDER BY COALESCE(rooms.name, 'room'), id DESC",
                 sql_of(%(query :ids, args: {}, returns: list(:RoomId) do select(:id).order(expr(:room_title), id: :desc) end), record: :id)
    assert_equal "SELECT id FROM rooms ORDER BY COALESCE(rooms.name, 'room') DESC",
                 sql_of(%(query :ids, args: {}, returns: list(:RoomId) do select(:id).order(expr(:room_title) => :desc) end), record: :id)
    assert_equal "SELECT rooms.id AS id #{USERS} ORDER BY UPPER(users.name) DESC",
                 sql_of(%(query :ids, args: {}, returns: list(:RoomId) do joins(:users).select(:id).order(expr(:user_label, :users) => :desc) end), record: :id)
  end

  def test_order_refusals
    refuses("execute :purge, args: {} do order(col(:users, :name)).delete end", "`users` is not joined")
    refuses("execute :purge, args: {} do order(expr(:nope)).delete end", "no `expr :nope` is declared")
    refuses("execute :purge, args: {} do order(expr(:now, :users)).delete end", "expr `now` has no `of:`")
    refuses("execute :purge, args: {} do joins(:users).order(col(:users, :name) => :up).delete end", "an order direction is `:asc`, `:desc` or `:nocase`")
    refuses("execute :purge, args: {} do joins(:users).order(col(:users, :nope) => :desc).delete end", "table `users` has no column `nope`")
  end

  # --- coalesce of an expr, a comparison with an expr, a condition on an association -------------------------------------------

  def test_coalesce_takes_an_expr_and_is_not_optional
    assert_equal "SELECT id, COALESCE(COALESCE(rooms.name, 'room'), 'none') AS title FROM rooms",
                 sql_of(%(query :titles, args: {}, returns: list(:RoomTitle) do select(:id, title: coalesce(expr(:room_title), "none")) end), record: :title)
    assert_equal "SELECT COALESCE(UPPER(users.name), '-') AS label #{LEFT_USERS}",
                 sql_of(%(query :labels, args: {}, returns: list(:RoomLabel) do left_joins(:users).select(label: coalesce(expr(:user_label, :users), "-")) end), record: :label)
    refused(source(%(query :labels, args: {}, returns: list(:RoomLabel) do left_joins(:users).select(label: expr(:user_label, :users)) end\n),
                   records: RECORDS.fetch(:label), routes: %(get "/x" do\n  json(labels)\nend\n)),
            "field `label` is :string in record `RoomLabel`, but the relation gives :string?")
  end

  def test_coalesce_of_an_expr_refusals
    refuses("query :labels, args: {}, returns: list(:RoomLabel) do select(label: coalesce(expr(:nope), \"-\")) end", "no `expr :nope` is declared")
    refuses("query :labels, args: {}, returns: list(:RoomLabel) do select(label: coalesce(expr(:user_label, :users), \"-\")) end", "`users` is not joined")
    refuses("query :labels, args: {}, returns: list(:RoomLabel) do select(label: coalesce(expr(:room_title))) end", "`coalesce` takes a column or `expr(:name)` and at least one more value")
  end

  def test_a_comparison_may_have_an_expr_on_the_left
    assert_equal "SELECT id FROM rooms WHERE COALESCE(rooms.name, 'room') > :x",
                 sql_of(%(query :ids, args: { x: :string }, returns: list(:RoomId) do where(gt(expr(:room_title), arg(:x))).select(:id) end), record: :id)
    assert_equal "SELECT rooms.id AS id #{USERS} WHERE UPPER(users.name) <= :x",
                 sql_of(%(query :ids, args: { x: :string }, returns: list(:RoomId) do joins(:users).where(lte(expr(:user_label, :users), arg(:x))).select(:id) end), record: :id)
    assert_equal "SELECT id FROM rooms WHERE COALESCE(rooms.name, 'room') >= 'a' AND COALESCE(rooms.name, 'room') < 'b'",
                 sql_of(%(query :ids, args: {}, returns: list(:RoomId) do where(gte(expr(:room_title), "a"), lt(expr(:room_title), "b")).select(:id) end), record: :id)
  end

  def test_a_comparison_with_an_expr_refusals
    refuses("query :ids, args: {}, returns: list(:RoomId) do where(gt(expr(:nope), 1)).select(:id) end", "no `expr :nope` is declared")
    refuses("query :ids, args: {}, returns: list(:RoomId) do where(gt(expr(:user_label, :users), 1)).select(:id) end", "`users` is not joined")
    refuses("query :ids, args: {}, returns: list(:RoomId) do where(gt(expr(:room_title))).select(:id) end", "`gt` takes a column (or `expr(:name)`) and a value")
  end

  MAIN_MEMBERSHIP = "has_one :main_membership, -> { where(user_id: 1) }, model: :Membership\n"

  def test_a_has_one_condition_is_part_of_the_join
    assert_equal "SELECT rooms.id AS id FROM rooms JOIN memberships ON memberships.room_id = rooms.id AND memberships.user_id = 1",
                 sql_of("#{MAIN_MEMBERSHIP}query :ids, args: {}, returns: list(:RoomId) do joins(:main_membership).select(:id) end", record: :id)
    assert_equal "SELECT rooms.id AS id FROM rooms LEFT OUTER JOIN memberships ON memberships.room_id = rooms.id AND memberships.user_id = 1",
                 sql_of("#{MAIN_MEMBERSHIP}query :ids, args: {}, returns: list(:RoomId) do left_joins(:main_membership).select(:id) end", record: :id)
    assert_equal "SELECT rooms.id AS id FROM rooms LEFT OUTER JOIN users ON users.id = rooms.id AND users.name = 'x' AND users.id = 5",
                 sql_of("has_one :named, -> { where(name: \"x\", id: 5) }, model: :User, foreign_key: :id\n" \
                        "query :ids, args: {}, returns: list(:RoomId) do left_joins(:named).select(:id) end", record: :id)
  end

  def test_a_has_one_condition_follows_the_polymorphic_columns_and_is_in_where_exists
    assert_equal "SELECT rooms.id AS id FROM rooms LEFT OUTER JOIN attachments ON attachments.record_id = rooms.id AND attachments.record_type = 'Room' AND attachments.id = 7",
                 sql_of("has_one :seventh, -> { where(id: 7) }, table: :attachments, as: :record\n" \
                        "query :ids, args: {}, returns: list(:RoomId) do left_joins(:seventh).select(:id) end", record: :id)
    assert_equal "SELECT COUNT(*) FROM rooms WHERE EXISTS (SELECT 1 FROM memberships WHERE memberships.room_id = rooms.id AND memberships.user_id = 1 AND memberships.id = :m)",
                 sql_of("#{MAIN_MEMBERSHIP}query :n, args: { m: :i64 }, returns: :i64 do where_exists(:main_membership, id: arg(:m)).count end")
  end

  def test_a_has_one_condition_refusals
    has = ->(decl, text) { refused(source("#{decl}\nquery :c, args: {}, returns: :i64 do count end\n", routes: %(get "/x" do\n  c.to_s\nend\n)), text) }
    has.call("has_one :m, -> { where(user_id: 1) }, model: :Membership, dependent: :delete_all", "a condition lambda and `dependent:` can not be combined")
    has.call("has_one :m, -> { where(user_id: 1) }, through: :memberships", "so a condition lambda does not apply")
    has.call("has_one :m, -> { where(nope: 1) }, model: :Membership", "table `memberships` has no column `nope`")
    has.call("has_one :m, -> { order(:id) }, model: :Membership", "the condition lambda holds one `where(column: literal, ...)`")
    has.call("has_one :m, -> { where(user_id: 1).order(:id) }, model: :Membership", "the condition lambda holds one `where(column: literal, ...)`")
    has.call("has_one :m, -> { where(user_id: arg(:u)) }, model: :Membership", "a condition's value is a string, integer, true or false literal, got CallNode")
    has.call("has_one :m, -> { where(\"user_id = 1\") }, model: :Membership", "the condition lambda's `where` takes `column: literal` pairs")
    has.call("has_one :m, ->(u) { where(user_id: 1) }, model: :Membership", "the condition lambda takes no parameters")
    has.call("has_one :m, -> { where(user_id: 1) }, 5, model: :Membership", "takes 1 to 2 positional argument(s), got 3")
    has.call("has_many :m, -> { where(user_id: 1) }, model: :Membership", "`has_many` takes 1 positional argument(s), got 2")
  end

  # --- the seam -------------------------------------------------------------------------------------------------------

  ROOM_FOR_USER = "SELECT rooms.id AS id, COALESCE(rooms.name, '') AS name #{MEMBERS} WHERE memberships.user_id = :user_id AND rooms.id = :id LIMIT 1".freeze
  ROOM_COUNT = "SELECT COUNT(*) FROM rooms"
  TOUCH_ROOM = "UPDATE rooms SET updated_at = #{NOW} WHERE id = :id".freeze

  AS_RELATIONS = <<~'RB'
    query :room_for_user, args: { user_id: :i64, id: :i64 }, returns: :RoomName? do visible_to(arg(:user_id)).where(id: arg(:id)).select(:id, name: coalesce(:name, "")) end
    query :room_count, args: {}, returns: :i64 do count end
    execute :touch_room, args: { id: :i64 } do where(id: arg(:id)).touch end
  RB

  AS_SQL = <<~RB
    query :room_for_user, args: { user_id: :i64, id: :i64 }, returns: :RoomName?, sql: "#{ROOM_FOR_USER}"
    query :room_count, args: {}, returns: :i64, sql: "#{ROOM_COUNT}"
    execute :touch_room, args: { id: :i64 }, sql: "#{TOUCH_ROOM}"
  RB

  CALLS = <<~RB
    get "/a" do
      json(room_for_user(user_id: 1, id: 2))
    end

    get "/b" do
      room_count.to_s
    end

    get "/c" do
      touch_room(id: 1).to_s
    end
  RB

  def test_the_emitted_rust_carries_the_rendered_sql
    rs = rust(source(AS_RELATIONS, records: RECORDS.fetch(:name), routes: CALLS))
    [ROOM_FOR_USER, ROOM_COUNT, TOUCH_ROOM].each { |sql| assert_includes rs, AxumDsl.rstr(sql) }
  end

  def test_a_relation_and_the_same_statements_in_sql_give_byte_identical_rust
    assert_same_rust rust(source(AS_RELATIONS, records: RECORDS.fetch(:name), routes: CALLS)),
                     rust(source(AS_SQL, records: RECORDS.fetch(:name), routes: CALLS))
  end

  def test_the_ir_entries_of_the_two_spellings_are_the_same
    from_sql = read(source(AS_SQL, records: RECORDS.fetch(:name), routes: CALLS)) { |ir, _f| ir["queries"] }
    from_relation = read(source(AS_RELATIONS, records: RECORDS.fetch(:name), routes: CALLS)) { |ir, _f| ir["queries"] }
    norm = ->(queries) { queries.map { |q| q.merge("at" => q["at"].sub(%r{\A.*/}, "")) } }
    assert_equal norm.call(from_sql), norm.call(from_relation)
  end

  # A statement written with sql: keeps exactly the entry it had before relations: same keys, same values.
  def test_an_sql_statement_keeps_its_ir_entry
    read(source(AS_SQL, records: RECORDS.fetch(:name), routes: CALLS)) do |ir, file|
      queries = ir["queries"]
      queries.each { |q| assert_equal "#{file}:#{q['line']}", q["at"] }
      plain = queries.map { |q| q.reject { |k, _| %w[at line].include?(k) } }
      assert_equal [
        { "name" => "room_for_user", "kind" => "query", "args" => [%w[user_id i64], %w[id i64]], "sql" => ROOM_FOR_USER,
          "shape" => "one", "record" => "RoomName", "fields" => %w[id name], "rtype" => "opt<struct:RoomName>" },
        { "name" => "room_count", "kind" => "query", "args" => [], "sql" => ROOM_COUNT,
          "shape" => "scalar", "type" => "i64", "nilable" => false, "rtype" => "i64" },
        { "name" => "touch_room", "kind" => "execute", "args" => [%w[id i64]], "sql" => TOUCH_ROOM,
          "shape" => "execute", "rtype" => "i64" }
      ], plain
      assert_equal %w[name kind args sql at line shape record fields rtype], queries.first.keys
    end
  end

  def test_statements_keep_their_declaration_order_across_the_spellings
    statements = <<~RB
      query :a_count, args: {}, returns: :i64 do count end
      query :b_count, args: {}, returns: :i64, sql: "SELECT COUNT(*) FROM rooms WHERE id > 0"
      execute :c_touch, args: { id: :i64 } do where(id: arg(:id)).touch end
      execute :d_drop, args: { id: :i64 }, sql: "DELETE FROM rooms WHERE id = :id"
    RB
    routes = %w[a_count b_count].map { |n| %(get "/#{n}" do\n  #{n}.to_s\nend\n) }.join +
             %w[c_touch d_drop].map { |n| %(get "/#{n}" do\n  #{n}(id: 1).to_s\nend\n) }.join
    read(source(statements, routes: routes)) do |ir, _file|
      assert_equal %w[a_count b_count c_touch d_drop], ir["queries"].map { |q| q["name"] }
      assert_equal ["SELECT COUNT(*) FROM rooms", "SELECT COUNT(*) FROM rooms WHERE id > 0",
                    "UPDATE rooms SET updated_at = #{NOW} WHERE id = :id", "DELETE FROM rooms WHERE id = :id"],
                   ir["queries"].map { |q| q["sql"] }
    end
  end

  # --- last, offset, distinct, insert(on_duplicate:), insert_from ------------------------------------------------------------

  def test_last_takes_the_last_rows_of_the_order_in_that_order
    assert_equal "SELECT id FROM (SELECT id, created_at AS _o1, id AS _o2 FROM rooms ORDER BY created_at DESC, id DESC LIMIT :n) ORDER BY _o1, _o2",
                 sql_of("query :recent, args: { n: :i64 }, returns: list(:RoomId) do order(:created_at, :id).last(arg(:n)).select(:id) end", record: :id)
    assert_equal "SELECT id FROM (SELECT rooms.id AS id, users.name AS _o1, UPPER(users.name) AS _o2 #{USERS} WHERE rooms.kind = 'a' ORDER BY users.name COLLATE NOCASE DESC, UPPER(users.name) LIMIT 40) ORDER BY _o1 COLLATE NOCASE, _o2 DESC",
                 sql_of(%(query :recent, args: {}, returns: list(:RoomId) do joins(:users).where(kind: "a").order(col(:users, :name) => :nocase, expr(:user_label, :users) => :desc).last(40).select(:id) end), record: :id)
  end

  def test_last_refusals
    refuses("query :n, args: {}, returns: list(:Rd) do last(3).select(:id) end", "last needs an order to take the last rows of")
    refuses("query :n, args: {}, returns: list(:Rd) do order(:id).limit(2).last(3).select(:id) end", "`last(n)` is the limit, so it can not be combined with `limit`")
    refuses("query :n, args: {}, returns: list(:Rd) do order(:id).last(3).limit(2).select(:id) end", "`limit` can not follow `last`")
    refuses("query :n, args: {}, returns: list(:Rd) do order(:id).last(3).last(2).select(:id) end", "`last` is given twice")
    refuses("query :n, args: {}, returns: list(:Rd) do order(:id).last(3).offset(1).select(:id) end", "`offset` can not be combined with `last`")
    refuses("query :n, args: {}, returns: list(:Rd) do distinct.order(:id).last(3).select(:id) end", "last can not be combined with distinct")
    refuses("query :n, args: {}, returns: list(:Rd) do order(:id).last(0).select(:id) end", "`last` takes a positive integer or `arg(:name)`")
    refuses("query :n, args: { n: :string }, returns: list(:Rd) do order(:id).last(arg(:n)).select(:id) end", "`last` takes an :i64 argument, `n` is :string")
    refuses("query :n, args: {}, returns: :i64 do order(:id).last(3).count end", "`last` gives the last rows as a list")
    refuses("query :n, args: {}, returns: :Rd? do order(:id).last(3).select(:id) end", "`last` gives the last rows as a list")
    refuses("execute :purge, args: {} do order(:id).last(3).delete end", "`last`, `offset` and `distinct` read rows")
    refuses("execute :purge, args: {} do where(id: Room.order(:id).last(3).select(:id)).delete end", "a subquery can not use last")
  end

  def test_offset_follows_limit
    assert_equal "SELECT id FROM rooms ORDER BY id LIMIT 5 OFFSET :o",
                 sql_of("query :page, args: { o: :i64 }, returns: list(:RoomId) do order(:id).limit(5).offset(arg(:o)).select(:id) end", record: :id)
    assert_equal "SELECT id FROM rooms ORDER BY id LIMIT :n OFFSET 20",
                 sql_of("query :page, args: { n: :i64 }, returns: list(:RoomId) do order(:id).limit(arg(:n)).offset(20).select(:id) end", record: :id)
  end

  def test_offset_refusals
    refuses("query :n, args: {}, returns: list(:Rd) do offset(2).select(:id) end", "`offset` follows `limit`")
    refuses("query :n, args: {}, returns: list(:Rd) do limit(2).offset(-1).select(:id) end", "`offset` takes a non-negative integer or `arg(:name)`")
    refuses("query :n, args: {}, returns: list(:Rd) do limit(2).offset(1).offset(1).select(:id) end", "`offset` is given twice")
    refuses("query :n, args: {}, returns: list(:Rd) do limit(2).offset.select(:id) end", "`offset` takes one integer or `arg(:name)`")
    refuses("query :n, args: { o: :string }, returns: list(:Rd) do limit(2).offset(arg(:o)).select(:id) end", "`offset` takes an :i64 argument, `o` is :string")
  end

  def test_distinct_is_select_distinct
    assert_equal "SELECT DISTINCT kind FROM rooms ORDER BY kind",
                 sql_of("query :kinds, args: {}, returns: list(:RoomKind) do distinct.select(:kind).order(:kind) end")
    assert_equal "DELETE FROM rooms WHERE kind IN (SELECT DISTINCT kind FROM rooms WHERE archived = 1)",
                 sql_of("execute :purge, args: {} do where(kind: Room.distinct.where(archived: true).select(:kind)).delete end")
  end

  def test_distinct_refusals
    refuses("query :n, args: {}, returns: :i64 do distinct.count end", "count takes a relation without distinct")
    refuses("query :n, args: {}, returns: :bool do distinct.exists end", "exists takes a relation without distinct")
    refuses("query :n, args: {}, returns: list(:Rd) do distinct(:id).select(:id) end", "`distinct` takes no arguments")
    refuses("execute :purge, args: {} do distinct.delete end", "`last`, `offset` and `distinct` read rows")
    refuses("execute :purge, args: {} do where(id: 1).or(where(id: 2).distinct).delete end", "`or` takes a chain of")
    refuses("execute :purge, args: {} do where(id: 1).or(distinct).delete end", "`distinct` can not be in it")
  end

  def test_insert_on_duplicate_skip
    assert_equal "INSERT OR IGNORE INTO rooms (name, kind, archived, created_at, updated_at) VALUES (:n, 'x', 0, #{NOW}, #{NOW})",
                 sql_of(%(execute :add, args: { n: :string } do insert(name: arg(:n), kind: "x", archived: false, on_duplicate: :skip) end))
    assert_equal "INSERT OR IGNORE INTO rooms (kind, name, archived, created_at, updated_at) VALUES ('x', :n, 0, #{NOW}, #{NOW}) RETURNING id",
                 sql_of(%(query :add, args: { n: :string }, returns: :i64 do insert(kind: "x", name: arg(:n), archived: false, on_duplicate: :skip, returning: :id) end))
  end

  def test_on_duplicate_refusals
    refuses(%(execute :add, args: {} do insert(name: "a", on_duplicate: :update) end), "`on_duplicate:` takes `:skip` (INSERT OR IGNORE), the only choice; got `:update`")
    refuses(%(execute :add, args: {} do insert(name: "a", on_duplicate: "skip") end), "`on_duplicate:` takes `:skip`")
    refuses(%(execute :add, args: {} do where(id: 1).update(name: "a", on_duplicate: :skip) end), "table `rooms` has no column `on_duplicate`")
  end

  def test_insert_from_reads_the_source_relation_and_stamps
    assert_equal "INSERT INTO rooms (name, kind, archived, created_at, updated_at) SELECT name, 'direct', 0, #{NOW}, #{NOW} FROM users",
                 sql_of(%(execute :copy, args: {} do insert_from(User, name: :name, kind: "direct", archived: false) end))
    assert_equal "INSERT OR IGNORE INTO rooms (id, name, kind, created_at, updated_at) SELECT :i, name, 'k', #{NOW}, #{NOW} FROM users WHERE id = :u",
                 sql_of(%(execute :copy, args: { i: :i64, u: :i64 } do insert_from(User.where(id: arg(:u)), id: arg(:i), name: :name, kind: "k", on_duplicate: :skip) end))
    assert_equal "INSERT INTO rooms (name, created_at, updated_at, kind) SELECT users.name, #{NOW}, #{NOW}, 'x' FROM memberships JOIN users ON users.id = memberships.user_id WHERE memberships.room_id = :r",
                 sql_of(%(execute :copy, args: { r: :i64 } do insert_from(Membership.joins(:user).where(room_id: arg(:r)), name: col(:user, :name), created_at: expr(:now), updated_at: expr(:now), kind: "x") end))
  end

  def test_insert_from_takes_expr_distinct_order_and_limit
    assert_equal "INSERT INTO rooms (name, kind, created_at, updated_at) SELECT DISTINCT UPPER(users.name), 'x', #{NOW}, #{NOW} FROM memberships JOIN users ON users.id = memberships.user_id ORDER BY memberships.id LIMIT 3 OFFSET 1",
                 sql_of(%(execute :copy, args: {} do insert_from(Membership.joins(:user).distinct.order(:id).limit(3).offset(1), name: expr(:user_label, :user), kind: "x") end))
  end

  def test_insert_from_refusals
    refuses("query :n, args: {}, returns: :i64 do insert_from(User, name: :name) end", "`insert_from` changes data, so it belongs in an `execute`")
    refuses(%(execute :copy, args: {} do insert_from(name: "x") end), "`insert_from` takes another model's relation and `column: value` pairs")
    refuses(%(execute :copy, args: {} do insert_from(User) end), "`insert_from` takes another model's relation and `column: value` pairs")
    refuses(%(execute :copy, args: {} do where(id: 1).insert_from(User, name: :name) end), "`insert_from` is the whole chain")
    refuses(%(execute :copy, args: {} do insert_from(User.select(:id), name: :name) end), "the relation given to `insert_from` takes no `select`")
    refuses(%(execute :copy, args: {} do insert_from(User.count, name: :name) end), "the relation given to `insert_from` is rows, so `count` can not be in it")
    refuses(%(execute :copy, args: {} do insert_from(User, nope: :name) end), "table `rooms` has no column `nope`")
    refuses(%(execute :copy, args: {} do insert_from(User, name: :nope) end), "table `users` has no column `nope`")
    refuses(%(execute :copy, args: {} do insert_from(User, name: :name, name: :name) end), "`name` is given twice")
    refuses(%(execute :copy, args: {} do insert_from(User, name: :name, returning: :id) end), "`returning:` is not supported by `insert_from`")
    refuses(%(execute :copy, args: {} do insert_from(User, name: :name, on_duplicate: :replace) end), "`on_duplicate:` takes `:skip`")
    refuses(%(execute :copy, args: {} do insert_from(Usr, name: :name) end), "no model `Usr` is declared")
    refuses(%(execute :copy, args: {} do insert_from(User, name: nil) end), "setting a column to nil is not supported by relations yet")
    refuses(%(execute :copy, args: {} do insert_from(User.order(:id).last(3), name: :name) end), "insert_from takes a relation without last")
    refuses(%(execute :copy, args: {} do insert_from(User, name: col(:user, :name)) end), "`user` is not joined")
    refuses(%(execute :copy, args: { x: :i64 } do insert_from(User, name: :name) end), "`args:` declares `x` but the chain never uses `arg(:x)`")
    refuses(%(execute :copy, args: {} do insert_from(User, name: arg(:zz)) end), "`arg(:zz)` is not in `args:`")
  end

  # --- a few refusals, with the suggestion; the rest are test/refusals/chain_*.rb ------------------------------------------

  def test_an_unknown_column_suggests_the_nearest
    error = refused(source(%(query :ids, args: {}, returns: list(:RoomId) do where(idd: 1).select(:id) end\n), records: RECORDS.fetch(:id),
                           routes: %(get "/x" do\n  json(ids)\nend\n)), "table `rooms` has no column `idd`")
    assert_includes error.suggestions, "id"
  end

  def test_a_bad_order_direction_lists_the_valid_ones
    refused(source(%(query :ids, args: {}, returns: list(:RoomId) do order(name: :upcase).select(:id) end\n), records: RECORDS.fetch(:id),
                   routes: %(get "/x" do\n  json(ids)\nend\n)), "an order direction is `:asc`, `:desc` or `:nocase`")
  end

  def test_an_unknown_scope_suggests_the_nearest
    error = refused(source(%(query :ids, args: {}, returns: list(:RoomId) do directz.select(:id) end\n), records: RECORDS.fetch(:id),
                           routes: %(get "/x" do\n  json(ids)\nend\n)), "`directz` is not a relation operation here")
    assert_includes error.suggestions, "directs"
  end

  # --- expr as a condition, expr binds, pick(expr), update to nil ---------------------------------------------------------

  def test_a_bool_expr_is_a_condition
    assert_equal "SELECT id FROM rooms WHERE (rooms.archived = 1)",
                 sql_of(%(query :ids, args: {}, returns: list(:RoomId) do where(expr(:archived_flag)).select(:id) end), record: :id)
    assert_equal "SELECT id FROM rooms WHERE kind = 'direct' AND NOT (rooms.archived = 1)",
                 sql_of(%(query :ids, args: {}, returns: list(:RoomId) do where(kind: "direct").where_not(expr(:archived_flag)).select(:id) end), record: :id)
    assert_equal "SELECT id FROM rooms WHERE (kind = 'direct') OR ((rooms.archived = 1))",
                 sql_of(%(query :ids, args: {}, returns: list(:RoomId) do where(kind: "direct").or(where(expr(:archived_flag))).select(:id) end), record: :id)
  end

  def test_an_expr_takes_the_binds_it_declares
    assert_equal "SELECT id FROM rooms WHERE (rooms.id = :u)",
                 sql_of(%(query :ids, args: { u: :i64 }, returns: list(:RoomId) do where(expr(:owned_by, who: arg(:u))).select(:id) end), record: :id)
    assert_equal "SELECT id FROM rooms WHERE (rooms.id = 7)",
                 sql_of(%(query :ids, args: {}, returns: list(:RoomId) do where(expr(:owned_by, who: 7)).select(:id) end), record: :id)
    assert_equal "SELECT id, rooms.id = :u AS mine FROM rooms",
                 sql_of(%(query :ids, args: { u: :i64 }, returns: list(:RoomMine) do select(:id, mine: expr(:owned_by, who: arg(:u))) end), record: :mine)
    assert_equal "SELECT id FROM rooms WHERE ((:p = 1 OR :q = 'x'))",
                 sql_of(%(query :ids, args: { p: :i64, q: :string }, returns: list(:RoomId) do where(expr(:either, b: arg(:q), a: arg(:p))).select(:id) end), record: :id)
  end

  # A :bool value fills an :i64 record field (SQLite holds a boolean as 0 or 1): the SQL is the same, the field is read as i64.
  def test_a_bool_value_fills_an_i64_field
    assert_equal "SELECT id, rooms.id = :u AS flag FROM rooms",
                 sql_of(%(query :ids, args: { u: :i64 }, returns: list(:RoomFlagInt) do select(:id, flag: expr(:owned_by, who: arg(:u))) end), record: :flag_int)
    assert_equal "SELECT id, archived AS flag FROM rooms",
                 sql_of(%(query :ids, args: {}, returns: list(:RoomFlagInt) do select(:id, flag: :archived) end), record: :flag_int)
  end

  def test_a_bool_value_fills_an_i64_field_only_that_way
    refused(source(%(query :ids, args: {}, returns: list(:RoomFlagBool) do select(:id, flag: :id) end\n),
                   records: RECORDS.fetch(:flag_bool), routes: %(get "/x" do\n  json(ids)\nend\n)),
            "field `flag` is :bool in record `RoomFlagBool`, but the relation gives :i64")
    src = source(%(query :ids, args: {}, returns: list(:RoomFlagOpt) do select(:id, flag: :archived) end\n),
                 records: RECORDS.fetch(:flag_opt), routes: %(get "/x" do\n  json(ids)\nend\n))
    refused(src, "field `flag` is :i64? in record `RoomFlagOpt`, but the relation gives :bool")
  end

  # A literal in `select` is typed from the literal: a string is :string, an integer :i64, true and false :bool (1 and 0).
  def test_a_literal_in_select
    assert_equal "SELECT id, \x27x\x27 AS tag, 1 AS n, 1 AS yes, 0 AS no FROM rooms",
                 sql_of(%(query :ids, args: {}, returns: list(:RoomLits) do select(:id, tag: "x", n: 1, yes: true, no: false) end), record: :lits)
    decl = %(query :ids, args: {}, returns: list(:RoomLitsDerived) do select(:id, tag: "x", n: 1, yes: true) end\n)
    read(source(decl, routes: %(get "/x" do\n  json(ids)\nend\n))) do |ir, _file|
      assert_equal [%w[id i64], %w[tag string], %w[n i64], %w[yes bool]], ir["records"].first["fields"].map { |f| [f["name"], f["type"]] }
      assert_equal [nil, nil, nil, nil], ir["records"].first["fields"].map { |f| f["optional"] }
    end
  end

  def test_a_literal_in_select_refusals
    refuses(%(query :ids, args: {}, returns: list(:RoomId) do select(:id, tag: nil) end), "a selected `nil` has no type")
    refuses(%(query :ids, args: {}, returns: list(:RoomId) do select(:id, tag: 1.5) end), "a selected value is `:column`")
    refuses(%(query :ids, args: {}, returns: list(:RoomId) do select(:id, 1) end), "a selected item without a name is a column")
    refused(source(%(query :ids, args: {}, returns: list(:RoomLits) do select(:id, tag: "x", n: "1", yes: true, no: false) end\n),
                   records: RECORDS.fetch(:lits), routes: %(get "/x" do\n  json(ids)\nend\n)),
            "field `n` is :i64 in record `RoomLits`, but the relation gives :string")
  end

  def test_pick_takes_an_expr
    assert_equal "SELECT COALESCE(rooms.name, 'room') FROM rooms WHERE id = :id LIMIT 1",
                 sql_of("query :title, args: { id: :i64 }, returns: :string? do where(id: arg(:id)).pick(expr(:room_title)) end")
  end

  def test_update_to_nil
    assert_equal "UPDATE rooms SET name = NULL WHERE id = :id",
                 sql_of("execute :clear, args: { id: :i64 } do where(id: arg(:id)).update_all(name: nil) end")
    assert_equal "UPDATE rooms SET name = NULL, updated_at = CASE WHEN name IS NOT NULL THEN #{NOW} ELSE updated_at END WHERE id = :id",
                 sql_of("execute :clear, args: { id: :i64 } do where(id: arg(:id)).update(name: nil) end")
    refuses("execute :clear, args: { id: :i64 } do where(id: arg(:id)).update_all(kind: nil) end", "column `kind` of `rooms` is NOT NULL, so it can not be set to nil")
  end

  def test_expr_condition_and_bind_refusals
    refuses("query :ids, args: {}, returns: list(:RoomId) do where(expr(:room_title)).select(:id) end", "expr `room_title` is :string, and a condition needs a :bool expr")
    refuses("query :ids, args: {}, returns: list(:RoomId) do where(expr(:nope)).select(:id) end", "no `expr :nope` is declared")
    refuses("query :ids, args: {}, returns: list(:RoomId) do where(expr(:owned_by)).select(:id) end", "expr `owned_by` needs `who:`: `expr(:owned_by, who: arg(:who))`")
    refuses("query :ids, args: {}, returns: list(:RoomId) do where(expr(:owned_by, whom: 1)).select(:id) end", "expr `owned_by` has no bind `whom` (binds: who)")
    refuses("query :ids, args: {}, returns: list(:RoomId) do where(expr(:archived_flag, who: 1)).select(:id) end", "expr `archived_flag` takes no binds (its declaration has no `args:`), so `who:` can not be given")
    refuses("query :ids, args: { u: :string }, returns: list(:RoomId) do where(expr(:owned_by, who: arg(:u))).select(:id) end", "expr `owned_by` takes `who` as :i64, but this value is :string")
    refuses(%(query :ids, args: {}, returns: list(:RoomId) do where(expr(:owned_by, who: "a")).select(:id) end), "expr `owned_by` takes `who` as :i64, but this value is :string")
    refuses("query :ids, args: {}, returns: list(:RoomId) do where(expr(:owned_by, who: nil)).select(:id) end", "bind `who` of expr `owned_by` can not be nil")
    refuses("query :ids, args: { u: :i64 }, returns: list(:RoomId) do where(expr(:owned_by, who: arg(:v))).select(:id) end", "`arg(:v)` is not in `args:`")
  end

  def test_an_expr_declares_its_binds_exactly
    refused(HEAD + "expr :e, type: :bool, args: { a: :i64 }, sql: \"1 = 1\"\n", "expr `e` declares `args: { a: ... }` but its sql never writes `:a`")
    refused(HEAD + "expr :e, type: :bool, args: { a: :i64 }, sql: \":a = :b\"\n", "expr `e` writes `:b` but `args:` does not declare it (declared: a)")
    refused(HEAD + "expr :e, type: :bool, sql: \":a = 1\"\n", "expr `e` has the placeholder `:a` in its sql")
    src = source("query :ids, args: {}, returns: list(:RoomId) do select(:id) end\n", records: RECORDS.fetch(:id), routes: %(get "/x" do\n  json(ids)\nend\n))
    models = read(src) { |ir, _file| AxumDsl::Db::Models.from_ir(ir["models"], ir["exprs"], AxumDsl::Db::Schema.from_ir(ir["tables"])) }
    assert_equal({ "who" => "i64" }, models.expr(:owned_by)[:args])
    assert_nil models.expr(:now)[:args]
  end
end
