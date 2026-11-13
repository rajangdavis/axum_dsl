# frozen_string_literal: true

# `has_one_attached` (docs/database.md, "Attachments"): the associations, the `attached(:name)` value and the statements
# `attach(:name, owner_id, stored)` runs, derived from one declaration. Pinned here by the exact SQL, the notice, the Rust the
# call becomes and the refusals. No cargo and no HTTP.
#
#   ruby -Ilib test/test_db_attached.rb
require "minitest/autorun"
require "tmpdir"
require "axum_dsl"

class TestDbAttached < Minitest::Test
  HEAD = <<~RB
    server "attached", version: "0.1.0"
    set :port, 8080
    database :sqlite, path: "x.db"
    setting :storage, env: "STORAGE_PATH", default: "storage/files"
  RB

  TABLES = <<~RB
    table :users do
      field :id, :i64
      field :name, :string
      field :updated_at, :time
    end

    table :active_storage_blobs do
      field :id, :i64
      field :key, :string
      field :filename, :string
      field :content_type, :string
      field :metadata, :string
      field :service_name, :string
      field :byte_size, :i64
      field :checksum, :string
      field :created_at, :time
    end

    table :active_storage_attachments do
      field :id, :i64
      field :name, :string
      field :record_type, :string
      field :record_id, :i64
      field :blob_id, :i64
      field :created_at, :time
    end
  RB

  MODELS = <<~RB
    model :Blob, table: :active_storage_blobs do
    end

    model :Attachment, table: :active_storage_attachments do
      belongs_to :blob, model: :Blob
    end
  RB

  USER = <<~RB
    model :User, table: :users do
      has_one_attached :avatar

      query :profile, args: { id: :i64 }, returns: :Profile? do
        where(id: arg(:id)).select(:name, avatar_attached: attached(:avatar))
      end

      query :with_avatar, args: {}, returns: :i64 do
        where(attached(:avatar)).count
      end

      query :without_avatar, args: {}, returns: :i64 do
        where_not(attached(:avatar)).count
      end

      query :avatar_files, args: { id: :i64 }, returns: :i64 do
        left_joins(:avatar_blob).where(id: arg(:id)).where_not(avatar_attachment: { blob_id: 0 }).count
      end
    end
  RB

  PARAMS = <<~RB
    params :Form do
      field :id, :i64, in: :path
      field :avatar, :upload, in: :form, name: "user[avatar]"
    end
  RB

  ROUTES = <<~RB
    get "/profile/:id", params: :Id do
      text(profile(id: params[:id]).nil?.to_s)
    end

    get "/counts" do
      text((with_avatar + without_avatar + avatar_files(id: 1)).to_s)
    end
  RB

  IDS = <<~RB
    params :Id do
      field :id, :i64, in: :path
    end
  RB

  REPLACE = <<~RB
    patch "/users/:id", params: :Form do
      stored = params[:avatar]&.store_file(setting(:storage))
      rows = transaction do
        attach(:avatar, params[:id], stored)
      end
      text(rows.to_s)
    end
  RB

  FRESH = <<~RB
    post "/users/:id", params: :Form do
      stored = params[:avatar]&.store_file(setting(:storage))
      rows = transaction do
        attach(:avatar, params[:id], stored, fresh: true)
      end
      text(rows.to_s)
    end
  RB

  STAMP = "strftime('%Y-%m-%d %H:%M:%f', 'now')"

  SQLS = {
    "insert_user_avatar_blob" => "INSERT INTO active_storage_blobs (key, filename, content_type, metadata, service_name, byte_size, checksum, created_at) " \
                                 "VALUES (:key, :filename, :content_type, :metadata, 'local', :byte_size, :checksum, #{STAMP})",
    "detach_user_avatar" => "DELETE FROM active_storage_attachments WHERE record_type = 'User' AND record_id = :user_id AND name = 'avatar'",
    "attach_user_avatar" => "INSERT INTO active_storage_attachments (name, record_type, record_id, blob_id, created_at) " \
                            "SELECT 'avatar', 'User', :user_id, id, #{STAMP} FROM active_storage_blobs WHERE key = :key",
    "touch_user_avatar" => "UPDATE users SET updated_at = #{STAMP} WHERE id = :user_id"
  }.freeze

  EXISTS = "EXISTS (SELECT 1 FROM active_storage_attachments WHERE record_type = 'User' AND record_id = users.id AND name = 'avatar')"

  def source(routes: REPLACE, user: USER, models: MODELS)
    "#{HEAD}#{TABLES}#{models}#{user}#{PARAMS}#{IDS}#{ROUTES}#{routes}"
  end

  def read(src)
    Dir.mktmpdir("attached") do |dir|
      file = File.join(dir, "attached.axum.rb")
      File.write(file, src)
      yield AxumDsl.read(file), file
    end
  end

  def rust(src)
    read(src) { |ir, file| AxumDsl::Emit.files(ir, file)["src/main.rs"] }
  end

  def refused(src, text)
    Dir.mktmpdir("attached") do |dir|
      file = File.join(dir, "attached.axum.rb")
      File.write(file, src)
      error = assert_raises(AxumDsl::CompileError) { AxumDsl.read(file) }
      assert_includes error.message, text
      error
    end
  end

  # --- what it derives -------------------------------------------------------------------------------------------------

  def test_the_four_statements_are_the_sql_of_the_hand_written_ones
    read(source) do |ir, _file|
      SQLS.each do |name, sql|
        q = ir["queries"].find { |x| x["name"] == name }
        refute_nil q, "#{name} is a statement"
        assert_equal sql, q["sql"]
        assert_equal %w[execute execute i64], q.values_at("kind", "shape", "rtype")
        assert_equal "has_one_attached :avatar", q.dig("derived", "from")
      end
      assert_equal %w[user_id], ir["queries"].find { |x| x["name"] == "detach_user_avatar" }["args"].map(&:first)
      assert_equal %w[user_id key], ir["queries"].find { |x| x["name"] == "attach_user_avatar" }["args"].map(&:first)
    end
  end

  def test_the_associations_are_derived_and_know_where_from
    read(source) do |ir, _file|
      user = ir["models"].find { |m| m["name"] == "User" }
      assert_equal %w[avatar_attachment avatar_blob], user["associations"].map { |a| a["name"] }
      assert_equal [{ "name" => "avatar", "from" => "has_one_attached :avatar", "at" => user["associations"][0].dig("derived", "at") }], user["attached"]
      assert_match(/attached\.axum\.rb:\d+\z/, user["attached"][0]["at"])
      registry = AxumDsl::Db::Models.from_ir(ir["models"], ir["exprs"], AxumDsl::Db::Schema.from_ir(ir["tables"]))
      attachment = registry.association("User", "avatar_attachment")
      assert_equal "active_storage_attachments", attachment[:target_table]
      assert_equal({ "record_type" => "User" }, attachment[:discriminator])
      assert_equal({ "name" => "avatar" }, attachment[:conditions])
      blob = registry.association("User", "avatar_blob")
      assert_equal "active_storage_blobs", blob[:target_table]
      assert_equal "avatar_attachment", blob[:through]
      assert_equal "has_one_attached :avatar", blob.dig(:derived, "from")
    end
  end

  def test_attached_is_an_exists_for_select_and_where
    read(source) do |ir, _file|
      sql = ->(name) { ir["queries"].find { |q| q["name"] == name }["sql"] }
      assert_equal "SELECT name, #{EXISTS} AS avatar_attached FROM users WHERE id = :id LIMIT 1", sql.("profile")
      assert_equal "SELECT COUNT(*) FROM users WHERE (#{EXISTS})", sql.("with_avatar")
      assert_equal "SELECT COUNT(*) FROM users WHERE NOT (#{EXISTS})", sql.("without_avatar")
    end
  end

  def test_the_derived_associations_join
    read(source) do |ir, _file|
      sql = ir["queries"].find { |q| q["name"] == "avatar_files" }["sql"]
      assert_includes sql, "LEFT OUTER JOIN active_storage_attachments ON active_storage_attachments.record_id = users.id AND " \
                           "active_storage_attachments.record_type = 'User' AND active_storage_attachments.name = 'avatar'"
      assert_includes sql, "LEFT OUTER JOIN active_storage_blobs ON active_storage_blobs.id = active_storage_attachments.blob_id"
    end
  end

  def test_the_notice_lists_the_statements_in_the_order_attach_runs_them
    AxumDsl::Notify.reset!
    read(source) { |_ir, _file| }
    notes = AxumDsl::Notify.notes.select { |n| n.code == "N-ATTACHED" }
    assert_equal 1, notes.size
    assert_equal :notice, notes.first.level
    message = notes.first.message
    assert_includes message, "has_one_attached :avatar of model \"User\""
    SQLS.each_with_index { |(name, sql), i| assert_includes message, "#{i + 1}. #{name}: #{sql}" }
  end

  # --- the call --------------------------------------------------------------------------------------------------------

  def test_attach_runs_the_four_statements_in_order_on_the_transactions_connection_and_a_nil_attaches_nothing
    rs = rust(source)
    at = SQLS.keys.map { |n| rs.index("query_#{n}_on(__tx,") }
    refute_includes at, nil
    assert_equal at.sort, at, "blob, detach, attach, touch"
    assert_includes rs, "Some(__u) => Some(axum_dsl_upload_store_file(__u, "
    assert_includes rs, "if let Some(__stored) = &stored {"
    assert_includes rs, "__stored.size"
    assert_includes rs, "struct AxumDslStored {"
    assert_includes rs, "async fn axum_dsl_upload_store_file("
  end

  def test_fresh_leaves_out_the_detach_and_the_touch_and_they_are_not_emitted_when_nothing_calls_them
    read(source(routes: FRESH)) do |ir, _file|
      names = ir["queries"].map { |q| q["name"] }
      assert_includes names, "insert_user_avatar_blob"
      assert_includes names, "attach_user_avatar"
      refute_includes names, "detach_user_avatar"
      refute_includes names, "touch_user_avatar"
    end
    rs = rust(source(routes: FRESH))
    refute_includes rs, "query_detach_user_avatar_on"
  end

  def test_a_model_that_is_never_attached_to_is_not_refused_for_its_unused_statements
    read(source(routes: %(patch "/users/:id", params: :Form do\n  text(setting(:storage) + params[:id].to_s + params[:avatar].nil?.to_s)\nend\n))) do |ir, _file|
      assert_empty(ir["queries"].select { |q| q["derived"] })
    end
  end

  # --- refusals --------------------------------------------------------------------------------------------------------

  def test_attach_outside_a_transaction_is_refused
    routes = %(patch "/users/:id", params: :Form do\n  stored = params[:avatar]&.store_file(setting(:storage))\n  attach(:avatar, params[:id], stored)\n  text("x")\nend\n)
    refused(source(routes: routes), "attach(:avatar) runs 4 statements that must stand or fall together, so it is called inside a transaction")
  end

  def test_an_unknown_attachment_name_gets_a_hint
    routes = REPLACE.sub("attach(:avatar,", "attach(:avatr,")
    refused(source(routes: routes), "no model declares `has_one_attached :avatr` (declared: :avatar)")
  end

  def test_attach_takes_a_stored_file
    routes = REPLACE.sub("attach(:avatar, params[:id], stored)", "attach(:avatar, params[:id], params[:id])")
    refused(source(routes: routes), "takes the file `upload&.store_file(setting(:storage))` gives")
  end

  def test_attach_takes_fresh_as_its_only_keyword
    routes = REPLACE.sub("attach(:avatar, params[:id], stored)", "attach(:avatar, params[:id], stored, replace: true)")
    refused(source(routes: routes), "attach takes `fresh: true` or `fresh: false` as its only keyword")
  end

  def test_the_models_that_own_active_storages_tables_are_needed
    refused(source(models: ""), "model \"User\" has_one_attached :avatar needs a model that owns the table `active_storage_attachments`")
  end

  def test_a_hand_written_statement_of_a_derived_name_is_refused
    hand = %(execute :touch_user_avatar, args: { id: :i64 }, sql: "UPDATE users SET name = name WHERE id = :id"\n)
    refused(source(models: MODELS + hand), "makes the statement `touch_user_avatar`, which is already declared")
  end

  def test_attached_names_the_models_own_attachments
    user = USER.sub("where(attached(:avatar)).count", "where(attached(:logo)).count")
    refused(source(user: user), "model \"User\" declares no `has_one_attached :logo` (it declares: avatar)")
  end

  def test_the_derived_names_may_not_clash_with_a_declared_association
    user = USER.sub("has_one_attached :avatar\n", "has_one :avatar_blob, model: :Blob, foreign_key: :id\n      has_one_attached :avatar\n")
    refused(source(user: user), "derives the association `avatar_blob`, which the model already declares")
  end
end