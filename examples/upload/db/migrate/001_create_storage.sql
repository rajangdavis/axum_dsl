-- Active Storage's tables as Rails writes them (db/schema.rb of a Rails 8 app), the two this service uses.
CREATE TABLE IF NOT EXISTS "active_storage_blobs" (
  "id" integer PRIMARY KEY AUTOINCREMENT NOT NULL,
  "byte_size" bigint NOT NULL,
  "checksum" varchar,
  "content_type" varchar,
  "created_at" datetime(6) NOT NULL,
  "filename" varchar NOT NULL,
  "key" varchar NOT NULL,
  "metadata" text,
  "service_name" varchar NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS "index_active_storage_blobs_on_key" ON "active_storage_blobs" ("key");

CREATE TABLE IF NOT EXISTS "active_storage_attachments" (
  "id" integer PRIMARY KEY AUTOINCREMENT NOT NULL,
  "blob_id" bigint NOT NULL,
  "created_at" datetime(6) NOT NULL,
  "name" varchar NOT NULL,
  "record_id" bigint NOT NULL,
  "record_type" varchar NOT NULL,
  CONSTRAINT "fk_rails_c3b3935057" FOREIGN KEY ("blob_id") REFERENCES "active_storage_blobs" ("id")
);
CREATE INDEX IF NOT EXISTS "index_active_storage_attachments_on_blob_id" ON "active_storage_attachments" ("blob_id");
CREATE UNIQUE INDEX IF NOT EXISTS "index_active_storage_attachments_uniqueness" ON "active_storage_attachments" ("record_type", "record_id", "name", "blob_id");
