# frozen_string_literal: true

# `send_file(path, content_type:)`: the response helper that reads a runtime path as bytes. These tests pin
# the emitted async read, the Content-Type, the 500 on a missing file and the refusals; the helper itself is
# exercised over HTTP by campfire_axum_dsl/test/e2e_campfire.sh's avatar route.
#
#   ruby -Ilib test/test_send_file.rb
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "axum_dsl"

class TestSendFile < Minitest::Test
  HEAD = <<~RB
    server "files", version: "0.1.0"
    setting :files, env: "FILES_PATH", default: "public"
  RB

  def files(body, head: HEAD)
    Dir.mktmpdir("sendfile") do |dir|
      file = File.join(dir, "files.axum.rb")
      File.write(file, head + body)
      AxumDsl::Emit.files(AxumDsl.read(file), file)
    end
  end

  def refusal(body, head: HEAD)
    error = assert_raises(AxumDsl::CompileError) { files(body, head: head) }
    error.message
  end

  def route(call = 'send_file("#{setting(:files)}/#{params[:name]}", content_type: "image/webp")')
    <<~RB
      params :FileName do
        field :name, :string, in: :path
      end

      get "/files/:name", params: :FileName do
        #{call}
      end
    RB
  end

  def test_the_body_is_read_when_the_request_runs_and_the_type_is_static
    main = files(route).fetch("src/main.rs")
    assert_includes main, "::tokio::fs::read(&__path).await"
    assert_includes main, "::axum::body::Body::from(__bytes)"
    assert_includes main, '::axum::http::HeaderValue::from_static("image/webp")'
    assert_includes main, "::axum::http::StatusCode::INTERNAL_SERVER_ERROR"
    assert_includes main, "let __path ="
  end

  def test_the_tokio_fs_feature_is_added_only_for_send_file
    files = files(route)
    assert_match(/tokio = \{ version = "1", features = \[.*"fs".*\] \}/, files.fetch("Cargo.toml"))
    no_file = files(<<~RB, head: "server \"files\", version: \"0.1.0\"\n")
      get "/" do
        "ok"
      end
    RB
    refute_match(/tokio = \{ version = "1", features = \[.*"fs".*\] \}/, no_file.fetch("Cargo.toml"))
  end

  def test_a_content_type_is_required
    message = refusal(route('send_file("#{setting(:files)}/#{params[:name]}")'))
    assert_includes message, "send_file needs `content_type:`"
  end

  def test_a_malformed_content_type_is_refused
    message = refusal(route('send_file("#{setting(:files)}/#{params[:name]}", content_type: "not a type")'))
    assert_includes message, "is a MIME type written `type/subtype`"
  end

  def test_the_path_is_a_string
    message = refusal(route('send_file(1, content_type: "text/plain")'))
    assert_includes message, "send_file takes a path string"
  end

  def test_send_file_is_only_a_route_or_filter_response
    message = refusal(<<~RB)
      helper :nope, args: [], returns: :string do
        send_file("x", content_type: "text/plain")
      end

      get "/" do
        nope
      end
    RB
    assert_includes message, "unsupported call `send_file`"
  end

  def test_a_status_statement_and_a_helper_status_are_refused
    message = refusal(<<~'RB')
      get "/" do
        status(201)
        send_file("#{setting(:files)}/x", status: 200, content_type: "text/plain")
      end
    RB
    assert_includes message, "status:"
  end
end
