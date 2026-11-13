# frozen_string_literal: true

# The relation IR and its SQLite renderer (lib/axum_dsl/db/rel.rb): every rule pinned by the exact SQL text.
#
#   ruby -Ilib test/test_db_rel.rb
require "minitest/autorun"
require "axum_dsl"
require "axum_dsl/db/rel"

class TestDbRel < Minitest::Test
  R = AxumDsl::Db::Rel
  NOW = "strftime('%Y-%m-%d %H:%M:%f', 'now')"

  def self.c(name, type, optional = false) = { name: name, type: type, optional: optional }

  SCHEMA = {
    "users" => [c("id", :i64), c("name", :string), c("email_address", :string), c("status", :i64),
                c("password_digest", :string, true)],
    "rooms" => [c("id", :i64), c("name", :string, true), c("created_at", :string), c("updated_at", :string)],
    "memberships" => [c("id", :i64), c("room_id", :i64), c("user_id", :i64), c("created_at", :string),
                      c("updated_at", :string)],
    "messages" => [c("id", :i64), c("room_id", :i64), c("created_at", :string), c("updated_at", :string)],
    "notes" => [c("id", :i64), c("title", :string)]
  }.freeze

  def col(column, table = nil) = R::Col.new(table, column)
  def arg(name) = R::Arg.new(name)
  def lit(value) = R::Lit.new(value)
  def eq(column, value, table = nil) = R::Eq.new(col(column, table), value)
  def rel(table, **opts) = R.from(table, **opts)
  def membership_join = R::Join.new("memberships", nil, col("room_id", "memberships"), col("id", "rooms"), nil)

  # The SQL of `SELECT id FROM users WHERE <preds>` so each predicate form is pinned in one line.
  def where_sql(*preds) = R.all(rel("users").where(*preds).selecting(col("id")), SCHEMA)[:sql]

  def member_ids = rel("memberships").where(eq("room_id", arg("room_id"))).selecting(col("user_id"))

  def assert_bad(pattern, &block)
    error = assert_raises(AxumDsl::CompileError, &block)
    assert_match pattern, error.message
  end

  # --- worked expectations ----------------------------------------------------------------------------------------

  def test_active_user_by_email
    digest = R::Sel.new(R::Fn.new("coalesce", [col("password_digest"), lit("")], nil), "password_digest")
    r = rel("users").where(eq("email_address", arg("email")), eq("status", lit(0))).selecting(col("id"), col("name"), digest)
    out = R.first(r, SCHEMA)
    assert_equal "SELECT id, name, COALESCE(password_digest, '') AS password_digest FROM users WHERE email_address = :email AND status = 0 LIMIT 1", out[:sql]
    assert_equal({ shape: :one,
                   fields: [{ name: "id", type: :i64, optional: false },
                            { name: "name", type: :string, optional: false },
                            { name: "password_digest", type: :string, optional: false }] }, out[:returns])
  end

  def test_room_for_user_with_a_join
    name = R::Sel.new(R::Fn.new("coalesce", [col("name", "rooms"), lit("")], nil), "name")
    r = rel("rooms").join(membership_join)
                    .where(eq("user_id", arg("user_id"), "memberships"), eq("id", arg("id"), "rooms"))
                    .selecting(col("id", "rooms"), name)
    out = R.first(r, SCHEMA)
    assert_equal "SELECT rooms.id AS id, COALESCE(rooms.name, '') AS name FROM rooms JOIN memberships ON memberships.room_id = rooms.id WHERE memberships.user_id = :user_id AND rooms.id = :id LIMIT 1", out[:sql]
    assert_equal [{ name: "id", type: :i64, optional: false }, { name: "name", type: :string, optional: false }],
                 out[:returns][:fields]
  end

  def test_touch_message
    out = R.touch(rel("messages").where(eq("id", arg("message_id"))), SCHEMA)
    assert_equal "UPDATE messages SET updated_at = #{NOW} WHERE id = :message_id", out[:sql]
    assert_equal({ shape: :execute }, out[:returns])
  end

  def test_revoke_room_members
    r = rel("memberships").where(eq("room_id", arg("room_id")), R::Not.new(eq("user_id", R::InIds.new("ids"))))
    assert_equal "DELETE FROM memberships WHERE room_id = :room_id AND user_id NOT IN (SELECT value FROM json_each('[' || :ids || ']'))",
                 R.delete(r, SCHEMA)[:sql]
  end

  def test_room_destroy_order
    body = { table: "action_text_rich_texts", fk: "record_id", discriminator: { "record_type" => "Message" }, mode: :delete_all, dependents: [] }
    attachments = body.merge(table: "active_storage_attachments")
    messages = { table: "messages", fk: "room_id", discriminator: nil, mode: :destroy,
                 dependents: [{ table: "boosts", fk: "message_id", discriminator: nil, mode: :delete_all, dependents: [] },
                              body, attachments,
                              { table: "message_search_index", fk: "rowid", discriminator: nil, mode: :delete_all, dependents: [] }] }
    memberships = { table: "memberships", fk: "room_id", discriminator: nil, mode: :delete_all, dependents: [] }
    out = R.destroy(rel("rooms").where(eq("id", arg("room_id"))), [messages, memberships], SCHEMA)
    assert_equal [
      "DELETE FROM boosts WHERE message_id IN (SELECT id FROM messages WHERE room_id = :room_id)",
      "DELETE FROM action_text_rich_texts WHERE record_type = 'Message' AND record_id IN (SELECT id FROM messages WHERE room_id = :room_id)",
      "DELETE FROM active_storage_attachments WHERE record_type = 'Message' AND record_id IN (SELECT id FROM messages WHERE room_id = :room_id)",
      "DELETE FROM message_search_index WHERE rowid IN (SELECT id FROM messages WHERE room_id = :room_id)",
      "DELETE FROM messages WHERE room_id = :room_id",
      "DELETE FROM memberships WHERE room_id = :room_id",
      "DELETE FROM rooms WHERE id = :room_id"
    ], out.map { |s| s[:sql] }
    assert(out.all? { |s| s[:returns] == { shape: :execute } })
  end

  def test_destroy_of_a_root_that_is_not_one_id_nests_the_root_conditions
    plan = [{ table: "memberships", fk: "room_id", mode: :delete_all }]
    out = R.destroy(rel("rooms").where(eq("name", arg("name"))), plan, SCHEMA)
    assert_equal ["DELETE FROM memberships WHERE room_id IN (SELECT id FROM rooms WHERE name = :name)",
                  "DELETE FROM rooms WHERE name = :name"], out.map { |s| s[:sql] }
  end

  def test_destroy_without_dependents_is_the_root_delete
    assert_equal ["DELETE FROM rooms WHERE id = :room_id"],
                 R.destroy(rel("rooms").where(eq("id", arg("room_id"))), [], SCHEMA).map { |s| s[:sql] }
  end

  def test_destroy_dependent_mode_and_nesting_errors
    root = rel("rooms").where(eq("id", arg("room_id")))
    assert_bad(/mode/) { R.destroy(root, [{ table: "messages", fk: "room_id", mode: :nullify }], SCHEMA) }
    nested = { table: "messages", fk: "room_id", mode: :delete_all, dependents: [{ table: "boosts", fk: "message_id", mode: :delete_all }] }
    assert_bad(/dependents/) { R.destroy(root, [nested], SCHEMA) }
  end

  # --- predicates -------------------------------------------------------------------------------------------------

  def test_eq_with_values
    assert_equal "SELECT id FROM users WHERE status = 0", where_sql(eq("status", lit(0)))
    assert_equal "SELECT id FROM users WHERE name = :name", where_sql(eq("name", arg("name")))
    assert_equal "SELECT id FROM users WHERE name = 'ann'", where_sql(eq("name", lit("ann")))
    assert_equal "SELECT id FROM users WHERE status = 1 AND status = 0", where_sql(eq("status", lit(true)), eq("status", lit(false)))
  end

  def test_eq_nil_is_null
    assert_equal "SELECT id FROM users WHERE name IS NULL", where_sql(eq("name", nil))
    assert_equal "SELECT id FROM users WHERE name IS NULL", where_sql(eq("name", lit(nil)))
  end

  def test_eq_with_a_list_is_in
    assert_equal "SELECT id FROM users WHERE status IN (1, 2)", where_sql(eq("status", [lit(1), lit(2)]))
  end

  def test_eq_with_a_relation_is_in_select
    assert_equal "SELECT id FROM users WHERE id IN (SELECT user_id FROM memberships WHERE room_id = :room_id)",
                 where_sql(eq("id", member_ids))
  end

  def test_eq_with_in_ids_is_json_each
    assert_equal "SELECT id FROM users WHERE id IN (SELECT value FROM json_each('[' || :ids || ']'))",
                 where_sql(eq("id", R::InIds.new("ids")))
  end

  def test_cmp_operators
    %w[> >= < <= <>].each do |op|
      assert_equal "SELECT id FROM users WHERE status #{op} 3", where_sql(R::Cmp.new(col("status"), op, lit(3)))
    end
    assert_equal "SELECT id FROM users WHERE name LIKE :q", where_sql(R::Cmp.new(col("name"), "LIKE", arg("q")))
  end

  def test_cmp_with_a_sub_relation_is_a_parenthesised_subquery
    assert_equal "SELECT id FROM users WHERE id > (SELECT user_id FROM memberships WHERE room_id = :room_id)",
                 where_sql(R::Cmp.new(col("id"), ">", member_ids))
  end

  def test_exists_is_a_correlated_select_1
    rooms = ->(pred) { R.all(rel("rooms").where(pred).selecting(col("id")), SCHEMA)[:sql] }
    inner = rel("memberships").where(eq("user_id", arg("u")))
    assert_equal "SELECT id FROM rooms WHERE EXISTS (SELECT 1 FROM memberships WHERE memberships.room_id = rooms.id AND memberships.user_id = :u)",
                 rooms.call(R::Exists.new(inner, membership_join, false))
    assert_equal "SELECT id FROM rooms WHERE NOT EXISTS (SELECT 1 FROM memberships WHERE memberships.room_id = rooms.id)",
                 rooms.call(R::Exists.new(rel("memberships"), membership_join, true))
    belongs = R::Join.new("rooms", nil, col("id", "rooms"), col("room_id", "memberships"), nil)
    assert_equal "SELECT id FROM memberships WHERE EXISTS (SELECT 1 FROM rooms WHERE rooms.id = memberships.room_id)",
                 R.all(rel("memberships").where(R::Exists.new(rel("rooms"), belongs, false)).selecting(col("id")), SCHEMA)[:sql]
  end

  def test_exists_adds_the_discriminator_and_aliases_a_table_that_collides
    tagged = R::Join.new("notes", nil, col("id", "notes"), col("id", "rooms"), { "title" => "Room" })
    assert_equal "SELECT id FROM rooms WHERE EXISTS (SELECT 1 FROM notes WHERE notes.id = rooms.id AND notes.title = 'Room')",
                 R.all(rel("rooms").where(R::Exists.new(rel("notes"), tagged, false)).selecting(col("id")), SCHEMA)[:sql]
    own = R::Join.new("rooms", nil, col("id", "rooms"), col("id", "rooms"), nil)
    assert_equal "SELECT id FROM rooms WHERE EXISTS (SELECT 1 FROM rooms AS rooms_exists WHERE rooms_exists.id = rooms.id AND rooms_exists.name = 'x')",
                 R.all(rel("rooms").where(R::Exists.new(rel("rooms").where(eq("name", lit("x"))), own, false)).selecting(col("id")), SCHEMA)[:sql]
  end

  def test_null_and_not_null
    assert_equal "SELECT id FROM users WHERE name IS NULL AND email_address IS NOT NULL",
                 where_sql(R::Null.new(col("name")), R::NotNull.new(col("email_address")))
  end

  def test_not_forms
    assert_equal "SELECT id FROM users WHERE status <> 0", where_sql(R::Not.new(eq("status", lit(0))))
    assert_equal "SELECT id FROM users WHERE name IS NOT NULL", where_sql(R::Not.new(eq("name", nil)))
    assert_equal "SELECT id FROM users WHERE status NOT IN (1, 2)", where_sql(R::Not.new(eq("status", [lit(1), lit(2)])))
    assert_equal "SELECT id FROM users WHERE id NOT IN (SELECT user_id FROM memberships WHERE room_id = :room_id)",
                 where_sql(R::Not.new(eq("id", member_ids)))
    assert_equal "SELECT id FROM users WHERE id NOT IN (SELECT value FROM json_each('[' || :ids || ']'))",
                 where_sql(R::Not.new(eq("id", R::InIds.new("ids"))))
  end

  def test_or_is_parenthesised
    pred = R::Or.new(eq("status", lit(0)), eq("status", lit(1)))
    assert_equal "SELECT id FROM users WHERE name = :n AND (status = 0 OR status = 1)", where_sql(eq("name", arg("n")), pred)
  end

  def test_or_where_joins_two_anded_sides_with_or
    pred = R::OrWhere.new([eq("status", lit(0))], [eq("status", lit(2)), eq("name", arg("n"))])
    assert_equal "SELECT id FROM users WHERE (status = 0) OR (status = 2 AND name = :n)", where_sql(pred)
    assert_equal "SELECT id FROM users WHERE ((status = 0) OR (status = 2 AND name = :n)) AND id = 1", where_sql(pred, eq("id", lit(1)))
    again = R::OrWhere.new([pred], [eq("id", lit(5))])
    assert_equal "SELECT id FROM users WHERE ((status = 0) OR (status = 2 AND name = :n)) OR (id = 5)", where_sql(again)
    assert_equal "DELETE FROM users WHERE ((status = 0) OR (status = 2 AND name = :n)) AND id = 1",
                 R.delete(rel("users").where(pred, eq("id", lit(1))), SCHEMA)[:sql]
  end

  def test_raw_predicate
    assert_equal "SELECT id FROM users WHERE LOWER(name) = 'x'", where_sql(R::RawPred.new("LOWER(name) = 'x'"))
  end

  def test_string_escaping_doubles_the_quote
    assert_equal "SELECT id FROM users WHERE name = 'it''s'", where_sql(eq("name", lit("it's")))
  end

  # --- selection, order, limit ------------------------------------------------------------------------------------

  def test_no_selection_is_every_column_in_schema_order
    out = R.all(rel("users"), SCHEMA)
    assert_equal "SELECT id, name, email_address, status, password_digest FROM users", out[:sql]
    assert_equal :list, out[:returns][:shape]
    assert_equal({ name: "password_digest", type: :string, optional: true }, out[:returns][:fields].last)
  end

  def test_no_selection_with_a_join_qualifies_and_aliases
    out = R.all(rel("rooms").join(membership_join), SCHEMA)
    assert_equal "SELECT rooms.id AS id, rooms.name AS name, rooms.created_at AS created_at, rooms.updated_at AS updated_at FROM rooms JOIN memberships ON memberships.room_id = rooms.id",
                 out[:sql]
  end

  def test_a_left_join_is_left_outer_and_what_it_selects_may_be_null
    join = R::Join.new("memberships", nil, col("room_id", "memberships"), col("id", "rooms"), nil, true)
    sels = [col("id", "rooms"), col("user_id", "memberships"),
            R::Sel.new(R::Fn.new("coalesce", [col("user_id", "memberships"), lit(0)], nil), "uid"),
            R::Sel.new(R::Expr.new("{t}.id + 1", :i64, "memberships"), "next")]
    out = R.all(rel("rooms").join(join).selecting(*sels), SCHEMA)
    assert_equal "SELECT rooms.id AS id, memberships.user_id AS user_id, COALESCE(memberships.user_id, 0) AS uid, memberships.id + 1 AS next FROM rooms LEFT OUTER JOIN memberships ON memberships.room_id = rooms.id",
                 out[:sql]
    assert_equal [false, true, false, true], out[:returns][:fields].map { |f| f[:optional] }
    inner = R::Join.new("memberships", nil, col("room_id", "memberships"), col("id", "rooms"), nil)
    assert_equal [false, false], R.all(rel("rooms").join(inner).selecting(col("id", "rooms"), col("user_id", "memberships")), SCHEMA)[:returns][:fields].map { |f| f[:optional] }
  end

  def test_table_alias_qualifies_its_columns
    join = R::Join.new("memberships", "m", col("room_id", "m"), col("id", "r"), nil)
    r = rel("rooms", table_alias: "r").join(join).where(eq("user_id", arg("user_id"), "m")).selecting(col("id", "r"))
    assert_equal "SELECT r.id AS id FROM rooms AS r JOIN memberships AS m ON m.room_id = r.id WHERE m.user_id = :user_id",
                 R.all(r, SCHEMA)[:sql]
  end

  def test_a_table_twice_with_one_alias_is_fine
    join = R::Join.new("rooms", "other", col("id", "other"), col("room_id", "messages"), nil)
    r = rel("messages").join(join).selecting(col("id", "other"))
    assert_equal "SELECT other.id AS id FROM messages JOIN rooms AS other ON other.id = messages.room_id", R.all(r, SCHEMA)[:sql]
  end

  def test_join_discriminator_follows_the_key_equality
    join = R::Join.new("memberships", nil, col("room_id", "memberships"), col("id", "rooms"), { "kind" => "Message" })
    schema = SCHEMA.merge("memberships" => SCHEMA["memberships"] + [self.class.c("kind", :string)])
    assert_equal "SELECT rooms.id AS id FROM rooms JOIN memberships ON memberships.room_id = rooms.id AND memberships.kind = 'Message'",
                 R.all(rel("rooms").join(join).selecting(col("id", "rooms")), schema)[:sql]
  end

  def test_selection_alias_and_functions
    sels = [R::Sel.new(col("name"), "title"),
            R::Sel.new(R::Fn.new("lower", [col("name")], :string), "lowered"),
            R::Sel.new(R::Raw.new("length(name)", :i64), "len"),
            R::Sel.new(R::Expr.new("{t}.id + 1", :i64), "next"),
            R::Sel.new(R::NOW, "stamp")]
    out = R.all(rel("users").selecting(*sels), SCHEMA)
    assert_equal "SELECT name AS title, lower(name) AS lowered, length(name) AS len, users.id + 1 AS next, #{NOW} AS stamp FROM users", out[:sql]
    assert_equal [{ name: "title", type: :string, optional: false }, { name: "lowered", type: :string, optional: false },
                  { name: "len", type: :i64, optional: false }, { name: "next", type: :i64, optional: false },
                  { name: "stamp", type: :string, optional: false }], out[:returns][:fields]
  end

  def test_expr_template_uses_the_alias
    r = rel("users", table_alias: "u").selecting(R::Sel.new(R::Expr.new("{t}.id", :i64), "uid"))
    assert_equal "SELECT u.id AS uid FROM users AS u", R.all(r, SCHEMA)[:sql]
  end

  def test_order_desc_and_nocase
    r = rel("users").selecting(col("id")).order_by(R::Order.new(col("name"), false, true), R::Order.new(col("id"), true, false))
    assert_equal "SELECT id FROM users ORDER BY name COLLATE NOCASE, id DESC", R.all(r, SCHEMA)[:sql]
    both = rel("users").selecting(col("id")).order_by(R::Order.new(col("name"), true, true))
    assert_equal "SELECT id FROM users ORDER BY name COLLATE NOCASE DESC", R.all(both, SCHEMA)[:sql]
  end

  def test_limit_literal_and_argument
    base = rel("users").selecting(col("id"))
    assert_equal "SELECT id FROM users LIMIT 20", R.all(base.limited(20), SCHEMA)[:sql]
    assert_equal "SELECT id FROM users LIMIT :n", R.all(base.limited(arg("n")), SCHEMA)[:sql]
  end

  def test_an_expr_with_binds_renders_each_bound_value_in_place_of_its_name
    owned = R::Expr.new("{t}.id = :who AND :tag <> ':who'", :bool, nil, { "who" => arg("u"), "tag" => lit("a'b") })
    assert_equal "SELECT id FROM users WHERE (users.id = :u AND 'a''b' <> ':who')", where_sql(R::Cond.new(owned, false))
    assert_equal "SELECT id FROM users WHERE NOT (users.id = :u AND 'a''b' <> ':who')", where_sql(R::Cond.new(owned, true))
  end

  def test_a_cond_is_parenthesised_among_other_predicates
    flag = R::Expr.new("{t}.status = 1 OR {t}.status = 2", :bool, nil)
    assert_equal "SELECT id FROM users WHERE name = 'x' AND (users.status = 1 OR users.status = 2)", where_sql(eq("name", lit("x")), R::Cond.new(flag, false))
  end

  def test_pick_an_expr
    sql = R.pick(rel("users").where(eq("id", arg("id"))), R::Expr.new("LOWER({t}.name)", :string, nil), SCHEMA)
    assert_equal "SELECT LOWER(users.name) FROM users WHERE id = :id LIMIT 1", sql[:sql]
    assert_equal({ shape: :scalar, type: :string, optional: true }, sql[:returns])
  end

  def test_update_a_nullable_column_to_nil
    r = rel("users").where(eq("id", arg("id")))
    assert_equal "UPDATE users SET password_digest = NULL WHERE id = :id", R.update(r, { "password_digest" => lit(nil) }, SCHEMA, stamp: false)[:sql]
    assert_bad(/column `name` of `users` is NOT NULL, so it can not be set to nil/) { R.update(r, { "name" => lit(nil) }, SCHEMA) }
  end

  def test_order_by_an_expr_and_a_joined_column
    lowered = R::Expr.new("LOWER({t}.name)", :string, nil)
    assert_equal "SELECT id FROM users ORDER BY LOWER(users.name), id DESC",
                 R.all(rel("users").selecting(col("id")).order_by(R::Order.new(lowered, false, false), R::Order.new(col("id"), true, false)), SCHEMA)[:sql]
    r = rel("rooms").join(membership_join).selecting(col("id", "rooms")).order_by(R::Order.new(col("user_id", "memberships"), true, false))
    assert_equal "SELECT rooms.id AS id FROM rooms JOIN memberships ON memberships.room_id = rooms.id ORDER BY memberships.user_id DESC",
                 R.all(r, SCHEMA)[:sql]
  end

  def test_clause_order
    r = rel("users").where(eq("status", lit(0))).selecting(col("id")).order_by(R::Order.new(col("id"), true, false)).limited(5)
    assert_equal "SELECT id FROM users WHERE status = 0 ORDER BY id DESC LIMIT 5", R.all(r, SCHEMA)[:sql]
  end

  def test_first_replaces_the_limit
    assert_equal "SELECT id FROM users LIMIT 1", R.first(rel("users").selecting(col("id")).limited(9), SCHEMA)[:sql]
  end

  # --- scalar terminals -------------------------------------------------------------------------------------------

  def test_count
    out = R.count(rel("users").where(eq("status", lit(0))), SCHEMA)
    assert_equal "SELECT COUNT(*) FROM users WHERE status = 0", out[:sql]
    assert_equal({ shape: :scalar, type: :i64, optional: false }, out[:returns])
  end

  def test_exists
    out = R.exists(rel("users").where(eq("email_address", arg("email"))), SCHEMA)
    assert_equal "SELECT EXISTS(SELECT 1 FROM users WHERE email_address = :email)", out[:sql]
    assert_equal({ shape: :scalar, type: :bool, optional: false }, out[:returns])
  end

  def test_pick
    out = R.pick(rel("users").where(eq("id", arg("id"))), col("name"), SCHEMA)
    assert_equal "SELECT name FROM users WHERE id = :id LIMIT 1", out[:sql]
    assert_equal({ shape: :scalar, type: :string, optional: true }, out[:returns])
  end

  def test_pick_of_an_aggregate_reads_the_whole_relation
    agg = R::Fn.new("group_concat", [col("id")], nil)
    out = R.pick(rel("notes").where(eq("title", arg("t"))), agg, SCHEMA)
    assert_equal "SELECT group_concat(id) FROM notes WHERE title = :t", out[:sql]
    assert_equal({ shape: :scalar, type: :string, optional: true }, out[:returns])
    out = R.pick(rel("notes").where(eq("title", arg("t"))), R::Fn.new("coalesce", [agg, lit("")], nil), SCHEMA)
    assert_equal "SELECT COALESCE(group_concat(id), '') FROM notes WHERE title = :t", out[:sql]
    assert_equal({ shape: :scalar, type: :string, optional: false }, out[:returns])
  end

  def test_an_aggregate_pick_takes_no_order_or_limit_and_is_no_selected_row
    agg = R::Fn.new("group_concat", [col("id")], nil)
    assert_bad(/without order, limit, offset or distinct/) { R.pick(rel("notes").order_by(R::Order.new(col("id"), false, false)), agg, SCHEMA) }
    assert_bad(/without order, limit, offset or distinct/) { R.pick(rel("notes").limited(1), agg, SCHEMA) }
    assert_bad(/can only be the value of a pick/) { R.all(rel("notes").selecting(R::Sel.new(agg, "ids")), SCHEMA) }
  end

  def test_pick_of_an_optional_column_and_of_a_join
    out = R.pick(rel("rooms").join(membership_join), col("name", "rooms"), SCHEMA)
    assert_equal "SELECT rooms.name FROM rooms JOIN memberships ON memberships.room_id = rooms.id LIMIT 1", out[:sql]
    assert_equal({ shape: :scalar, type: :string, optional: true }, out[:returns])
  end

  def test_count_and_exists_refuse_order_and_limit
    assert_bad(/count/) { R.count(rel("users").limited(1), SCHEMA) }
    assert_bad(/exists/) { R.exists(rel("users").order_by(R::Order.new(col("id"), false, false)), SCHEMA) }
  end

  # --- insert, update, delete -------------------------------------------------------------------------------------

  def test_insert_appends_timestamps_created_first
    out = R.insert("rooms", { "name" => arg("name") }, SCHEMA)
    assert_equal "INSERT INTO rooms (name, created_at, updated_at) VALUES (:name, #{NOW}, #{NOW})", out[:sql]
    assert_equal({ shape: :execute }, out[:returns])
  end

  def test_insert_keeps_a_timestamp_the_caller_gave
    out = R.insert("rooms", { name: arg("name"), updated_at: lit("x") }, SCHEMA)
    assert_equal "INSERT INTO rooms (name, updated_at, created_at) VALUES (:name, 'x', #{NOW})", out[:sql]
  end

  def test_insert_without_timestamp_columns
    assert_equal "INSERT INTO notes (title) VALUES (:title)", R.insert("notes", { "title" => arg("title") }, SCHEMA)[:sql]
  end

  def test_insert_returning
    out = R.insert("notes", { "title" => lit("a") }, SCHEMA, returning: :id)
    assert_equal "INSERT INTO notes (title) VALUES ('a') RETURNING id", out[:sql]
    assert_equal({ shape: :scalar, type: :i64, optional: false }, out[:returns])
  end

  def test_insert_on_duplicate_skip_is_insert_or_ignore
    out = R.insert("rooms", { "name" => arg("name") }, SCHEMA, on_duplicate: :skip)
    assert_equal "INSERT OR IGNORE INTO rooms (name, created_at, updated_at) VALUES (:name, #{NOW}, #{NOW})", out[:sql]
    assert_equal "INSERT OR IGNORE INTO notes (title) VALUES ('a') RETURNING id",
                 R.insert("notes", { "title" => lit("a") }, SCHEMA, returning: :id, on_duplicate: :skip)[:sql]
    assert_bad(/on_duplicate: takes :skip, not :update/) { R.insert("notes", { "title" => lit("a") }, SCHEMA, on_duplicate: :update) }
  end

  # --- insert_from ---------------------------------------------------------------------------------------------------

  def test_insert_from_selects_the_values_from_the_source
    source = rel("users").where(eq("status", lit(0)))
    out = R.insert_from("memberships", source, { room_id: arg("room_id"), user_id: col("id") }, SCHEMA, on_duplicate: :skip)
    assert_equal "INSERT OR IGNORE INTO memberships (room_id, user_id, created_at, updated_at) SELECT :room_id, id, #{NOW}, #{NOW} FROM users WHERE status = 0", out[:sql]
    assert_equal({ shape: :execute }, out[:returns])
  end

  def test_insert_from_a_joined_ordered_limited_distinct_source
    source = rel("rooms").join(membership_join).where(eq("user_id", arg("u"), "memberships")).distinctly
                         .order_by(R::Order.new(col("id", "rooms"), false, false)).limited(5)
    out = R.insert_from("notes", source, { "title" => col("name", "rooms") }, SCHEMA)
    assert_equal "INSERT INTO notes (title) SELECT DISTINCT rooms.name FROM rooms JOIN memberships ON memberships.room_id = rooms.id WHERE memberships.user_id = :u ORDER BY rooms.id LIMIT 5", out[:sql]
  end

  def test_insert_from_refusals
    users = rel("users")
    assert_bad(/table `memberships` has no column `nope`/) { R.insert_from("memberships", users, { "nope" => col("id") }, SCHEMA) }
    assert_bad(/table `users` has no column `nope`/) { R.insert_from("memberships", users, { "user_id" => col("nope") }, SCHEMA) }
    assert_bad(/without a selection/) { R.insert_from("memberships", users.selecting(col("id")), { "user_id" => col("id") }, SCHEMA) }
    assert_bad(/without last/) { R.insert_from("memberships", users.last_of(1), { "user_id" => col("id") }, SCHEMA) }
    assert_bad(/needs at least one value/) { R.insert_from("notes", users, {}, SCHEMA) }
    assert_bad(/on_duplicate: takes :skip/) { R.insert_from("notes", users, { "title" => col("name") }, SCHEMA, on_duplicate: :replace) }
  end

  # --- last, offset, distinct ------------------------------------------------------------------------------------------

  def asc(value, table = nil) = R::Order.new(col(value, table), false, false)

  def test_last_reverses_the_order_inside_and_restores_it_outside
    r = rel("messages").where(eq("room_id", arg("r"))).selecting(col("id")).order_by(asc("created_at"), asc("id")).last_of(40)
    out = R.all(r, SCHEMA)
    assert_equal "SELECT id FROM (SELECT id, created_at AS _o1, id AS _o2 FROM messages WHERE room_id = :r ORDER BY created_at DESC, id DESC LIMIT 40) ORDER BY _o1, _o2", out[:sql]
    assert_equal [{ name: "id", type: :i64, optional: false }], out[:returns][:fields]
  end

  def test_last_with_a_joined_column_an_expression_nocase_and_an_argument
    upper = R::Expr.new("UPPER({t}.name)", :string, "rooms")
    r = rel("rooms").join(membership_join).selecting(col("id", "rooms"))
                    .order_by(R::Order.new(col("user_id", "memberships"), true, false), R::Order.new(upper, false, true)).last_of(arg("n"))
    assert_equal "SELECT id FROM (SELECT rooms.id AS id, memberships.user_id AS _o1, UPPER(rooms.name) AS _o2 FROM rooms JOIN memberships ON memberships.room_id = rooms.id ORDER BY memberships.user_id, UPPER(rooms.name) COLLATE NOCASE DESC LIMIT :n) ORDER BY _o1 DESC, _o2 COLLATE NOCASE",
                 R.all(r, SCHEMA)[:sql]
  end

  def test_last_refusals
    base = rel("messages").selecting(col("id"))
    assert_bad(/last needs an order/) { R.all(base.last_of(3), SCHEMA) }
    assert_bad(/last can not be combined with distinct/) { R.all(base.order_by(asc("id")).distinctly.last_of(3), SCHEMA) }
    assert_bad(/last can not be combined with offset/) { R.all(base.order_by(asc("id")).last_of(3).offset_by(1), SCHEMA) }
    assert_bad(/last gives a list/) { R.first(base.order_by(asc("id")).last_of(3), SCHEMA) }
    assert_bad(/a subquery can not use last/) { where_sql(eq("id", base.order_by(asc("id")).last_of(3))) }
  end

  def test_offset_follows_limit
    base = rel("users").selecting(col("id")).order_by(asc("id"))
    assert_equal "SELECT id FROM users ORDER BY id LIMIT 10 OFFSET 20", R.all(base.limited(10).offset_by(20), SCHEMA)[:sql]
    assert_equal "SELECT id FROM users ORDER BY id LIMIT :n OFFSET :o", R.all(base.limited(arg("n")).offset_by(arg("o")), SCHEMA)[:sql]
    assert_bad(/an offset needs a limit/) { R.all(base.offset_by(20), SCHEMA) }
  end

  def test_distinct_is_select_distinct
    assert_equal "SELECT DISTINCT status FROM users", R.all(rel("users").selecting(col("status")).distinctly, SCHEMA)[:sql]
    assert_equal "SELECT id FROM users WHERE status IN (SELECT DISTINCT status FROM users)",
                 where_sql(eq("status", rel("users").selecting(col("status")).distinctly))
    assert_bad(/count takes a relation without distinct/) { R.count(rel("users").distinctly, SCHEMA) }
    assert_bad(/exists takes a relation without distinct/) { R.exists(rel("users").distinctly, SCHEMA) }
  end

  def test_update_adds_the_stamp_last
    r = rel("rooms").where(eq("id", arg("id")))
    assert_equal "UPDATE rooms SET name = :name, updated_at = CASE WHEN name IS NOT :name THEN #{NOW} ELSE updated_at END WHERE id = :id",
                 R.update(r, { "name" => arg("name") }, SCHEMA)[:sql]
  end

  def test_update_stamps_when_any_of_its_values_changes
    r = rel("memberships").where(eq("id", arg("id")))
    assert_equal "UPDATE memberships SET room_id = :room, user_id = 7, updated_at = CASE WHEN room_id IS NOT :room OR user_id IS NOT 7 THEN #{NOW} ELSE updated_at END WHERE id = :id",
                 R.update(r, { "room_id" => arg("room"), "user_id" => lit(7) }, SCHEMA)[:sql]
  end

  def test_update_without_the_stamp
    r = rel("rooms").where(eq("id", arg("id")))
    assert_equal "UPDATE rooms SET name = :name WHERE id = :id", R.update(r, { "name" => arg("name") }, SCHEMA, stamp: false)[:sql]
  end

  def test_update_keeps_an_updated_at_the_caller_set
    r = rel("rooms").where(eq("id", arg("id")))
    assert_equal "UPDATE rooms SET updated_at = :at, name = :name WHERE id = :id",
                 R.update(r, { updated_at: arg("at"), name: arg("name") }, SCHEMA)[:sql]
  end

  def test_update_of_a_table_without_updated_at_has_no_stamp
    assert_equal "UPDATE notes SET title = :t WHERE id = :id",
                 R.update(rel("notes").where(eq("id", arg("id"))), { "title" => arg("t") }, SCHEMA)[:sql]
  end

  def test_delete
    assert_equal "DELETE FROM memberships WHERE room_id = :room_id",
                 R.delete(rel("memberships").where(eq("room_id", arg("room_id"))), SCHEMA)[:sql]
    assert_equal "DELETE FROM notes", R.delete(rel("notes"), SCHEMA)[:sql]
  end

  # --- errors -----------------------------------------------------------------------------------------------------

  def test_the_same_table_twice_without_aliases_is_an_error
    join = R::Join.new("rooms", nil, col("id", "rooms"), col("room_id", "messages"), nil)
    assert_bad(/appears twice/) { R.all(rel("rooms").join(join), SCHEMA) }
  end

  def test_update_and_delete_with_joins_are_errors
    r = rel("rooms").join(membership_join)
    assert_bad(/update/) { R.update(r, { "name" => lit("a") }, SCHEMA) }
    assert_bad(/delete/) { R.delete(r, SCHEMA) }
  end

  def test_touch_without_updated_at_is_an_error
    assert_bad(/updated_at/) { R.touch(rel("notes"), SCHEMA) }
  end

  def test_an_untyped_raw_in_a_selection_is_an_error
    assert_bad(/needs a type/) { R.all(rel("users").selecting(R::Sel.new(R::Raw.new("1", nil), "one")), SCHEMA) }
  end

  def test_a_selected_function_needs_a_name_and_a_type
    assert_bad(/needs a name/) { R.all(rel("users").selecting(R::Raw.new("1", :i64)), SCHEMA) }
    assert_bad(/needs a type/) { R.all(rel("users").selecting(R::Sel.new(R::Fn.new("lower", [col("name")], nil), "n")), SCHEMA) }
  end

  def test_an_unknown_column_of_a_known_table_is_an_error
    assert_bad(/no column `nope`/) { where_sql(eq("nope", lit(1))) }
    assert_bad(/no column `nope`/) { R.insert("notes", { "nope" => lit(1) }, SCHEMA) }
  end

  def test_an_unknown_table_or_alias_is_an_error
    assert_bad(/unknown table or alias `x`/) { where_sql(eq("id", lit(1), "x")) }
    assert_bad(/no table `ghosts`/) { R.all(rel("ghosts"), SCHEMA) }
  end

  def test_bad_comparison_and_literals_are_errors
    assert_bad(/unknown comparison/) { where_sql(R::Cmp.new(col("id"), "=", lit(1))) }
    assert_bad(/literal/) { where_sql(R::Cmp.new(col("id"), ">", lit(nil))) }
    assert_bad(/equality/) { where_sql(R::Not.new(R::Null.new(col("id")))) }
  end

  def test_a_subquery_needs_one_column
    assert_bad(/exactly one column/) { where_sql(eq("id", rel("memberships"))) }
  end

  # --- derived fields and immutability -----------------------------------------------------------------------------

  def test_plain_columns_take_the_schema_type_and_optionality
    fields = R.all(rel("rooms").selecting(col("id"), col("name")), SCHEMA)[:returns][:fields]
    assert_equal [{ name: "id", type: :i64, optional: false }, { name: "name", type: :string, optional: true }], fields
  end

  def test_coalesce_takes_the_type_of_its_first_argument_and_is_not_optional
    sel = R::Sel.new(R::Fn.new("coalesce", [col("status"), lit(0)], nil), "status")
    assert_equal [{ name: "status", type: :i64, optional: false }], R.all(rel("users").selecting(sel), SCHEMA)[:returns][:fields]
  end

  def test_building_does_not_change_the_original
    base = rel("users")
    changed = base.where(eq("id", lit(1))).limited(2)
    assert_empty base.predicates
    assert_nil base.limit
    assert changed.frozen?
    assert base.predicates.frozen?
  end
end
