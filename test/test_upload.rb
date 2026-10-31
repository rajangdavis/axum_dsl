# frozen_string_literal: true

# Uploads (docs/dsl.md, "Uploads"), asserted on the emitted crate: an `:upload` field makes its form group read
# multipart/form-data through AxumDslForm, the struct takes the file by its wire name, `avatar.store(root)` is the
# Disk service's upload, the method override layer reads a multipart `_method`, and the rules that keep an upload
# in a form are refused. test/e2e_upload.sh drives the running service with curl -F.
#
#   ruby -Ilib test/test_upload.rb
require "minitest/autorun"
require "tmpdir"
require "axum_dsl"

class TestUpload < Minitest::Test
  def compile_files(body)
    Dir.mktmpdir("upload") do |dir|
      file = File.join(dir, "upload.axum.rb")
      File.write(file, "server \"upload\", version: \"0.1.0\"\n#{body}")
      AxumDsl::Emit.files(AxumDsl.read(file), file)
    end
  end

  def main(body) = compile_files(body)["src/main.rs"]

  APP = <<~RB
    setting :storage, env: "STORAGE_PATH", default: "storage/files"
    params :Join do
      field :name, :string, in: :form, name: "user[name]"
      field :avatar, :upload, in: :form, name: "user[avatar]"
    end
    post "/join", params: :Join do
      avatar = params[:avatar]
      if avatar.nil?
        text("joined \#{params[:name]}")
      else
        key = avatar.store(setting(:storage))
        text("\#{avatar.filename} \#{avatar.content_type} \#{avatar.size} \#{avatar.checksum} \#{key}")
      end
    end
  RB

  def test_the_group_is_read_by_the_multipart_aware_extractor
    main = main(APP)
    assert_includes main, "AxumDslForm(__form): AxumDslForm<Join>"
    refute_includes main, "axum::extract::Form(__form)"
  end

  def test_the_struct_keeps_the_text_wire_name_and_skips_the_file
    main = main(APP)
    assert_includes main, "    #[serde(rename = \"user[name]\")]\n    name: String,"
    assert_includes main, "    #[serde(skip)]\n    avatar: Option<AxumDslUpload>,"
    refute_includes main, "rename = \"user[avatar]\""
  end

  def test_the_struct_takes_its_file_by_the_wire_name
    main = main(APP)
    assert_includes main, "impl AxumDslFormExtras for Join {"
    assert_includes main, "self.avatar = axum_dsl_take_upload(files, \"user[avatar]\");"
  end

  def test_the_runtime_answers_a_urlencoded_body_as_axum_does_and_parses_a_multipart_one
    main = main(APP)
    assert_includes main, "<::axum::extract::Form<T> as ::axum::extract::FromRequest<S>>::from_request(req, state)"
    assert_includes main, "fn axum_dsl_multipart_parse(body: &[u8], boundary: &str)"
    assert_includes main, "if parts.len() >= 4096 {"
    assert_includes main, "if files > 128 {"
    # a file input nobody chose a file in: Rack drops the part
    assert_includes main, "Some(filename) if filename.is_empty() => {}"
    assert_includes main, "::base64::Engine::encode(&::base64::engine::general_purpose::STANDARD, ::md5::Md5::digest(data))"
  end

  # Active Storage's analyzed metadata: ImageAnalyzer's width and height in Rails' key order, read from the header.
  def test_an_upload_carries_the_analyzed_metadata
    main = main(APP)
    assert_includes main, "metadata: axum_dsl_upload_metadata(data),"
    assert_includes main, %q(format!(r#"{{"identified":true,"width":{width},"height":{height},"analyzed":true}}"#))
    assert_includes main, %q(None => r#"{"identified":true,"analyzed":true}"#.to_string(),)
    assert_includes main, %q(if d.starts_with(b"\x89PNG\r\n\x1a\n") && d.get(12..16) == Some(b"IHDR") {)
  end

  def test_store_is_the_disk_services_upload_under_a_new_key
    main = main(APP)
    # A String setting reads as `settings().storage.clone()`, borrowed for the &str root.
    assert_match(/axum_dsl_upload_store\(&avatar, &settings\(\)\.storage(\.clone\(\))?\)\.await\?/, main)
    assert_includes main, "const ALPHABET: &[u8; 36] = b\"0123456789abcdefghijklmnopqrstuvwxyz\";"
    assert_includes main, "(0..28).map("
    assert_includes main, ".join(&key[0..2]).join(&key[2..4])"
  end

  def test_the_cargo_lines_follow_the_features_used
    cargo = compile_files(APP)["Cargo.toml"]
    assert_includes cargo, 'md-5 = "0.10"'
    assert_includes cargo, 'base64 = "0.22"'
    assert_includes cargo, 'rand = "0.9"'
    assert_includes cargo, '"fs"'
    refute_includes cargo, "multer"
    plain = compile_files("params :Note do\n  field :body, :string, in: :form\nend\npost(\"/n\", params: :Note) { text(params[:body]) }\n")
    refute_includes plain["Cargo.toml"], "md-5"
    refute_includes plain["src/main.rs"], "AxumDslForm"
    assert_includes plain["src/main.rs"], "axum::extract::Form(__form)"
  end

  def test_a_group_without_a_store_has_no_key_generator_or_rand
    main = compile_files(<<~RB)
      params :Join do
        field :avatar, :upload, in: :form
      end
      post "/join", params: :Join do
        text(params[:avatar]&.filename || "none")
      end
    RB
    refute_includes main["src/main.rs"], "axum_dsl_upload_store"
    refute_includes main["Cargo.toml"], "rand = "
    assert_includes main["src/main.rs"], "__o.filename"
  end

  LISTS = <<~RB
    params :Room do
      field :id, :i64, in: :path
      field :name, :string, in: :form, name: "room[name]"
      field :user_ids, list(:i64), in: :form, name: "user_ids[]", default: []
      field :tags, list(:string), in: :form, name: "tags[]", optional: true
    end
    patch "/rooms/:id", params: :Room do
      text("\#{params[:name]} \#{params[:user_ids].length}")
    end
  RB

  def test_a_list_field_in_a_form_is_read_from_every_repeated_key
    main = main(LISTS)
    assert_includes main, "AxumDslForm(__form): AxumDslForm<RoomForm>"
    assert_includes main, "&[\"user_ids[]\", \"tags[]\"]"
    assert_includes main, "pairs.iter().filter(|(name, _)| name == \"user_ids[]\")"
    assert_includes main, "match v.parse::<i64>() {"
    assert_includes main, "match Ok::<String, ()>(v.clone()) {"
    # absent: the default, or nil for an optional list
    assert_includes main, "self.user_ids = default_room_form_user_ids();"
    assert_includes main, "self.tags = Some(list);"
    assert_includes main, "    #[serde(skip)]\n    user_ids: Vec<i64>,"
    assert_includes main, "    #[serde(skip)]\n    tags: Option<Vec<String>>,"
    refute_includes main, "rename = \"user_ids[]\""
  end

  def test_a_list_form_needs_no_upload_checksum_use_but_keeps_the_parser
    main = main(LISTS)
    assert_includes main, "fn axum_dsl_urldecode(input: &[u8]) -> String {"
    assert_includes main, "T::list_names()"
    assert_includes main, "if list_names.contains(&name.as_str())"
  end

  def test_a_required_list_without_a_default_is_missing_when_absent
    main = main(LISTS.sub(", default: []", ""))
    assert_includes main, "return Err(format!(\"missing field `{}`\", \"user_ids[]\"));"
  end

  def test_the_method_override_layer_reads_a_multipart_part
    main = main(<<~RB)
      use_layer :method_override
      delete "/notes" do
        text("gone")
      end
    RB
    assert_includes main, "fn axum_dsl_method_override_multipart(content_type: &str, body: &[u8]) -> Option<String>"
    assert_includes main, "part.filename.is_none() && part.name == \"_method\""
    assert_includes main, "axum_dsl_method_override_multipart(&multipart_type, &bytes)"
    assert_includes main, "::axum::body::to_bytes(body, AXUM_DSL_MULTIPART_LIMIT)"
    refute_includes main, "AxumDslUpload"
  end

  def test_an_upload_is_in_a_form_only
    error = assert_raises(AxumDsl::CompileError) do
      compile_files("params :P do\n  field :avatar, :upload\nend\npost(\"/p\", params: :P) { text(\"x\") }\n")
    end
    assert_includes error.message, "is an :upload, which a browser sends in a multipart/form-data body: say `in: :form`"
  end

  def test_an_upload_takes_no_constraints
    error = assert_raises(AxumDsl::CompileError) do
      compile_files("params :P do\n  field :avatar, :upload, in: :form, min_length: 1\nend\npost(\"/p\", params: :P) { text(\"x\") }\n")
    end
    assert_includes error.message, "`min_length:` does not apply to an :upload field"
  end

  def test_an_upload_form_is_a_post
    error = assert_raises(AxumDsl::CompileError) do
      compile_files("params :P do\n  field :avatar, :upload, in: :form\nend\nget(\"/p\", params: :P) { text(\"x\") }\n")
    end
    assert_includes error.message, "reads params `P` from a form, but a browser sends a form body only on POST"
  end

  def test_a_list_of_uploads_is_not_supported
    error = assert_raises(AxumDsl::CompileError) do
      compile_files("params :P do\n  field :avatars, list(:upload), in: :form\nend\npost(\"/p\", params: :P) { text(\"x\") }\n")
    end
    assert_includes error.message, "`list(:upload)` is not supported yet"
  end

  def test_upload_is_not_a_params_name
    error = assert_raises(AxumDsl::CompileError) do
      compile_files("params :Upload do\n  field :a, :string, in: :form\nend\npost(\"/p\", params: :Upload) { text(\"x\") }\n")
    end
    assert_includes error.message, "`Upload` is the type of an :upload field"
  end

  def test_the_file_object_has_four_fields_and_one_method
    error = assert_raises(AxumDsl::CompileError) do
      compile_files(APP.sub("avatar.checksum", "avatar.bytes"))
    end
    assert_includes error.message, "Upload has no field `bytes`"
  end

  def test_store_takes_a_string_root
    error = assert_raises(AxumDsl::CompileError) { compile_files(APP.sub("store(setting(:storage))", "store(3)")) }
    assert_includes error.message, "store takes the storage root as a string"
  end
end
