# frozen_string_literal: true

# `active_storage_disk_path`, `active_storage_verified_id`, `active_storage_verified_key` and `inline_disposition`
# (docs/body-language.md), asserted on the emitted crate: Active Storage's disk service URLs, signed with
# ActiveStorage.verifier (SHA1 over the "ActiveStorage" key, standard base64, the `_rails` envelope). The wire
# bytes are checked by the Campfire parity run (GET /rails/active_storage/representations/redirect/...).
#
#   ruby -Ilib test/test_active_storage_disk.rb
require "minitest/autorun"
require "tmpdir"
require "axum_dsl"

class TestActiveStorageDisk < Minitest::Test
  ROUTES = <<~RB
    setting :secret_key, env: "SECRET_KEY_BASE", secret: true
    params :Redirect do
      field :signed_blob_id, :string, in: :path
    end
    params :Disk do
      field :encoded_key, :string, in: :path
      field :filename, :string, in: :path
    end
    get "/r/:signed_blob_id", params: :Redirect do
      blob_id = active_storage_verified_id(params[:signed_blob_id], secret: :secret_key)
      return halt(404, "") if blob_id.nil?
      path = active_storage_disk_path("abc", "moon.jpg", "image/jpeg", secret: :secret_key)
      headers "Location" => "\#{request_base_url}\#{path}", "X-Rack-Defaults" => "engine"
      halt(302, "")
    end
    get "/d/:encoded_key/:filename", params: :Disk do
      key = active_storage_verified_key(params[:encoded_key], secret: :secret_key)
      return halt(404, "") if key.nil?
      headers "Content-Disposition" => inline_disposition(params[:filename])
      "ok"
    end
    params :DiskPut do
      field :token, :string, in: :path
    end
    post "/direct" do
      key = active_storage_key
      headers "X-Signed" => active_storage_blob_id(7, secret: :secret_key)
      text("\#{request_base_url}\#{active_storage_direct_upload_url(key, "text/plain", 6, "XrY7u+Ae7tCTyyK7j1rNww==", secret: :secret_key)}")
    end
    put "/disk/:token", params: :DiskPut do
      status = active_storage_disk_upload(params[:token], "/tmp/storage", secret: :secret_key)
      return head(204) if status == 204
      return head(404) if status == 404
      head(422)
    end
  RB

  def main_rs
    Dir.mktmpdir("as") do |dir|
      file = File.join(dir, "as.axum.rb")
      File.write(file, "server \"as\", version: \"0.1.0\"\n#{ROUTES}")
      AxumDsl::Emit.files(AxumDsl.read(file), file)["src/main.rs"]
    end
  end

  def test_the_signed_key_carries_rails_blob_key_fields_in_order
    main = main_rs
    assert_includes main, '{{\"key\":{},\"disposition\":{},\"content_type\":{},\"service_name\":\"local\"}}'
    assert_includes main, '"blob_key", Some(&expires)'
    assert_includes main, "now.saturating_add(300_000)", "ActiveStorage.service_urls_expire_in is five minutes"
  end

  def test_verification_checks_digest_purpose_and_expiry
    main = main_rs
    assert_includes main, "fn axum_dsl_active_storage_verified(secret: &[u8], token: &str, purpose: &str)"
    assert_includes main, 'axum_dsl_active_storage_verified(secret, token, "blob_id")'
    assert_includes main, 'axum_dsl_active_storage_verified(secret, token, "blob_key")'
    assert_includes main, "if expires <= axum_dsl_iso8601_ms(now).as_str()"
  end

  def test_direct_upload_token_is_rails_blob_token
    main = main_rs
    assert_includes main, '{{\"key\":{},\"content_type\":{},\"content_length\":{},\"checksum\":{},\"service_name\":\"local\"}}'
    assert_includes main, '"blob_token", Some(&expires)'
    assert_includes main, 'format!("/rails/active_storage/disk/{}", axum_dsl_path_segment(&token))'
    assert_equal 1, main.scan("fn axum_dsl_path_segment(").size, "the segment escaper is written once"
  end

  def test_disk_upload_is_disk_controller_update
    main = main_rs
    assert_includes main, 'axum_dsl_active_storage_verified(secret, token, "blob_token") else { return 404 }'
    assert_includes main, "::md5::Md5::digest(body)"
    assert_includes main, "axum_dsl_active_storage_disk_upload(settings().secret_key.as_bytes(), "
    assert_includes main, "&__headers, &__body, "
    assert_includes main, "fn axum_dsl_active_storage_key() -> String"
    assert_includes main, "axum_dsl_active_storage_blob_id(settings().secret_key.as_bytes(), (7) as i64)"
  end

  def test_disk_upload_is_for_a_route_body
    Dir.mktmpdir("as") do |dir|
      file = File.join(dir, "as.axum.rb")
      File.write(file, <<~RB)
        server "as", version: "0.1.0"
        setting :secret_key, env: "SECRET_KEY_BASE", secret: true
        helper :up, args: [:string], returns: :i64 do |t|
          active_storage_disk_upload(t, "/tmp", secret: :secret_key)
        end
      RB
      err = assert_raises(AxumDsl::CompileError) { AxumDsl.read(file) }
      assert_includes err.message, "active_storage_disk_upload reads the request body"
    end
  end

  def test_the_disposition_is_actiondispatch_content_disposition
    main = main_rs
    assert_includes main, "fn axum_dsl_content_disposition(disposition: &str, filename: &str) -> String"
    assert_includes main, 'axum_dsl_content_disposition("inline", '
    assert_equal 1, main.scan("fn axum_dsl_iso8601_ms(").size, "the clock formatter is written once"
    assert_equal 1, main.scan("fn axum_dsl_content_disposition(").size
  end
end
