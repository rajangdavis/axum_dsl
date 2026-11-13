# frozen_string_literal: true

# `image_variant(path, filename, width, height)`: Active Storage's resize_to_limit variant made with libvips
# (lib/axum_dsl/image_variant.rb), as an Upload. Byte-for-byte agreement with Rails is campfire_axum_dsl's fuzz run;
# these pin the compiled surface.
#
#   ruby -Ilib test/test_image_variant.rb
require "minitest/autorun"
require "tmpdir"
require "axum_dsl"

class TestImageVariant < Minitest::Test
  def files(body)
    src = <<~RB
      server "iv", version: "0.1.0"
      get "/v" do
        #{body}
      end
    RB
    Dir.mktmpdir("iv") do |dir|
      file = File.join(dir, "iv.axum.rb")
      File.write(file, src)
      AxumDsl::Emit.files(AxumDsl.read(file), file)
    end
  end

  OK = <<~RB.freeze
    variant = image_variant("/tmp/in.png", "in.png", 512, 512)
      return halt(422, "") if variant.nil?
      text("\#{variant.size} \#{variant.checksum} \#{variant.metadata} \#{variant.store("/tmp/store")}")
  RB

  def test_the_variant_is_an_upload_made_by_libvips_opened_at_run_time
    out = files(OK)
    main = out["src/main.rs"]
    assert_includes main, 'axum_dsl_image_variant("/tmp/in.png", "in.png", (512) as i64, (512) as i64).await'
    assert_includes main, '::libloading::Library::new("libvips.so.42")'
    assert_includes main, "c\"no_rotate\".as_ptr(), 1 as ::std::ffi::c_int"
    assert_includes main, "let mask_values: [f64; 9] = [-1.0, -1.0, -1.0, -1.0, 32.0, -1.0, -1.0, -1.0, -1.0];"
    assert_includes main, "struct AxumDslUpload {"
    assert_includes out["Cargo.toml"], 'libloading = "0.8"'
    assert_includes out["Cargo.toml"], '"form"'
  end

  def test_without_it_there_is_no_libvips
    out = files('text("ok")')
    refute_includes out["src/main.rs"], "libvips"
    refute_includes out["Cargo.toml"], "libloading"
  end

  def test_the_arguments_are_checked
    err = assert_raises(AxumDsl::CompileError) { files('image_variant("/a.png", "a.png", 512)') }
    assert_match(/image_variant takes the source path/, err.message)
    err = assert_raises(AxumDsl::CompileError) { files('x = image_variant("/a.png", "a.png", "512", 512)' + "\n  text(\"\")") }
    assert_match(/image_variant's width is an integer/, err.message)
  end
end
