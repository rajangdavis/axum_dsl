# frozen_string_literal: true

# An upload's content type and metadata as Active Storage identifies and analyzes it (multipart.rb): Marcel 1.1's tables
# are emitted with the upload runtime. Agreement with Rails is campfire_axum_dsl's test/differential/fuzz_identify.
#
#   ruby -Ilib test/test_identify.rb
require "minitest/autorun"
require "tmpdir"
require "axum_dsl"

class TestIdentify < Minitest::Test
  def main(src)
    Dir.mktmpdir("identify") do |dir|
      file = File.join(dir, "identify.axum.rb")
      File.write(file, src)
      AxumDsl::Emit.files(AxumDsl.read(file), file)["src/main.rs"]
    end
  end

  UPLOAD = <<~RB
    server "identify", version: "0.1.0"
    params :Up do
      field :file, :upload, in: :form
    end
    post "/up", params: :Up do
      text(params[:file]&.content_type || "")
    end
  RB

  def test_an_upload_is_identified_with_marcels_tables
    out = main(UPLOAD)
    assert_includes out, "content_type: axum_dsl_identify_content_type(data, &filename, part.content_type.as_deref()),"
    assert_includes out, 'static AXUM_DSL_MARCEL_MAGIC: &[(&str, &[AxumDslMarcelRule])] = &['
    assert_includes out, '("image/png", &[AxumDslMarcelRule { at: 0, upto: None, value: Some(b"\x89\x50\x4e\x47\x0d\x0a\x1a\x0a"), children: None }]),'
    assert_includes out, '("txt", "text/plain"),'
    assert_includes out, "fn axum_dsl_exif_orientation(d: &[u8]) -> Option<u16> {"
  end

  def test_the_tables_are_marcels_order_and_sorted_for_lookup
    data = JSON.parse(File.read(AxumDsl::Multipart::MARCEL))
    assert_equal "1.1.0", data["version"]
    exts = data["extensions"].map(&:first)
    assert_equal exts.sort, exts
    # Magic's order is Marcel's: the first matching type wins, so OOXML comes before application/zip.
    order = data["magic"].map(&:first)
    assert_operator order.index("application/vnd.openxmlformats-officedocument.wordprocessingml.document"), :<, order.index("application/zip")
  end

  def test_without_uploads_there_are_no_tables
    refute_includes main(%(server "x", version: "0.1.0"\nget "/" do\n  text("ok")\nend\n)), "AXUM_DSL_MARCEL"
  end
end
