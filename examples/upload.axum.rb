# typed: false
# Uploads (docs/dsl.md, "Uploads"): a form with a file input is multipart/form-data, and a params group with an
# `:upload` field reads it the way Rack does (a urlencoded body still works). `avatar.store(root)` writes the file
# the way Active Storage's Disk service does and gives its key; the blob and attachment rows are this file's own SQL,
# in Active Storage's tables. `use_layer :method_override` reads the `_method` part of a multipart body, so the
# `patch` below is reached by a form that says `<input type="hidden" name="_method" value="patch">`.
# `typed: false` because Sorbet knows the DSL's calls (rbi/dsl.rbi) but not the query names this file declares.
# `make e2e-upload` builds this file and test/e2e_upload.sh drives it with curl -F; port 8111.
server "upload", version: "0.1.0"
set :port, 8111

use_layer :method_override

# Active Storage's Disk service root; a blob lives at <root>/<key[0,2]>/<key[2,2]>/<key>.
setting :storage, env: "STORAGE_PATH", default: "storage/files"

database :sqlite, path: "upload.sqlite3", env: "DATABASE_PATH"
migrations "upload/db/migrate"

record :Blob do
  field :id, :i64
  field :key, :string
  field :filename, :string
  field :content_type, :string
  field :byte_size, :i64
  field :checksum, :string
  field :service_name, :string
end

query :find_blob, args: { id: :i64 }, returns: :Blob?, sql: <<~SQL
  SELECT id, key, filename, content_type, byte_size, checksum, service_name FROM active_storage_blobs WHERE id = :id
SQL

# ActiveStorage::Blob.create_and_upload!: the row (the file is written by `store`).
query :insert_blob, args: { key: :string, filename: :string, content_type: :string, byte_size: :i64, checksum: :string }, returns: :i64, sql: <<~SQL
  INSERT INTO active_storage_blobs (key, filename, content_type, metadata, service_name, byte_size, checksum, created_at)
  VALUES (:key, :filename, :content_type, '{"identified":true}', 'local', :byte_size, :checksum, strftime('%Y-%m-%d %H:%M:%f', 'now'))
  RETURNING id
SQL

# has_one_attached :avatar on a User: one attachment, so a new one replaces the old.
execute :detach_avatar, args: { record_id: :i64 }, sql: <<~SQL
  DELETE FROM active_storage_attachments WHERE record_type = 'User' AND record_id = :record_id AND name = 'avatar'
SQL

execute :attach_avatar, args: { record_id: :i64, blob_id: :i64 }, sql: <<~SQL
  INSERT INTO active_storage_attachments (name, record_type, record_id, blob_id, created_at)
  VALUES ('avatar', 'User', :record_id, :blob_id, strftime('%Y-%m-%d %H:%M:%f', 'now'))
SQL

params :Join do
  field :name, :string, in: :form, name: "user[name]"
  field :avatar, :upload, in: :form, name: "user[avatar]"
end

params :Profile do
  field :id, :i64, in: :path
  field :bio, :string, in: :form, name: "user[bio]", optional: true
  field :avatar, :upload, in: :form, name: "user[avatar]"
end

# The closed-room form: the member checkboxes repeat `user_ids[]`; with none checked the key is absent (Rails' `params.fetch(:user_ids, [])`).
params :Room do
  field :id, :i64, in: :path
  field :name, :string, in: :form, name: "room[name]"
  field :user_ids, list(:i64), in: :form, name: "user_ids[]", default: []
end

params :BlobId do
  field :id, :i64, in: :path
end

# The join form (users/new): name, e-mail and a file input. With no file chosen the browser still sends an empty
# part, which Rack drops, so the avatar is nil.
post "/join", params: :Join, description: "Text fields and an optional avatar, multipart or urlencoded" do
  avatar = params[:avatar]
  if avatar.nil?
    text("joined #{params[:name]} without an avatar")
  else
    text("joined #{params[:name]} with #{avatar.filename} (#{avatar.content_type}, #{avatar.size} bytes, md5 #{avatar.checksum})")
  end
end

# The profile form: multipart, `_method=patch` in the body, a bio and the avatar. The file is stored, a blob row
# records it and an attachment ties it to the user.
patch "/users/:id/profile", params: :Profile, description: "Store the avatar as an Active Storage blob and attach it" do
  avatar = params[:avatar]
  return halt(422, "no file chosen") if avatar.nil?

  key = avatar.store(setting(:storage))
  blob_id = insert_blob(key: key, filename: avatar.filename, content_type: avatar.content_type, byte_size: avatar.size, checksum: avatar.checksum)
  detach_avatar(record_id: params[:id])
  attach_avatar(record_id: params[:id], blob_id: blob_id)
  text("blob #{blob_id} key #{key} bio #{params[:bio] || ''}")
end

patch "/rooms/:id", params: :Room, description: "A repeated form key read as a list, urlencoded or multipart" do
  text("room #{params[:id]} #{params[:name]} members #{params[:user_ids].length}: #{params[:user_ids].join(",")}")
end

get "/blobs/:id", params: :BlobId, description: "A blob row, or 404" do
  blob = find_blob(id: params[:id])
  if blob.nil?
    halt(404, "no such blob")
  else
    json(blob)
  end
end
