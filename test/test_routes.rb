# frozen_string_literal: true

# L5 in Ruby, and the differential that closes the loop when `make test-ruby-rust` runs it: build a
# generated crate, start the service, and compare what it answers over HTTP against the value the
# *same* spec/shims/string.yml entry gives in Ruby. The catalog's literal `out` is asserted against
# Ruby first, so the catalog, the Ruby shim and the generated Rust must all agree -- a build that
# quietly swapped `chars().count()` for `len()` (bytes, not characters) or Ruby's strip set for
# Rust's `trim()` (which eats NBSP) is caught by the HTTP comparison, not by any Ruby-only check.
#
#   ruby -Ilib test/test_routes.rb               # the emitted Rust only; no cargo
#   AXUM_CARGO=1 ruby -Ilib test/test_routes.rb  # also builds and drives the service
require "minitest/autorun"
require "net/http"
require "open3"
require "rbconfig"
require "socket"
require "tmpdir"
require "uri"
require "yaml"
require "axum_dsl"

class TestRoutes < Minitest::Test
  EXE = File.expand_path("../exe/axum_dsl", __dir__)
  CATALOG = YAML.safe_load_file(File.expand_path("../spec/shims/string.yml", __dir__))
  NAME = "routes"

  # The source this test builds: one route per catalog entry the differential drives. `set :port`
  # takes a free port chosen per run, so two gates can run at once without colliding.
  def source(port)
    <<~RB
      server #{NAME.inspect}, version: "0.1.0"
      set :port, #{port}

      params :One do
        field :s, :string, in: :query, description: "the text to operate on"
      end

      get "/length", params: :One, description: "String#length" do
        text(params[:s].length.to_s)
      end

      get "/strip", params: :One, description: "String#strip" do
        text(params[:s].strip)
      end

      get "/reverse", params: :One, description: "String#reverse" do
        text(params[:s].reverse)
      end

      get "/to_i", params: :One, description: "String#to_i" do
        text(params[:s].to_i.to_s)
      end
    RB
  end

  # One differential row: the catalog entry that defines the semantics, the route that emits it, and
  # an input taken from that entry's own examples. The test refuses if the input is no longer one of
  # the entry's examples, so a catalog edit cannot leave the route silently untested.
  CASES = [
    ["String#length",  "/length",  "héllo"],
    ["String#strip",   "/strip",   "\u00a0x\u00a0"],
    ["String#reverse", "/reverse", "héllo"],
    ["String#to_i",    "/to_i",    "  -42xyz"]
  ].freeze

  def with_source(src)
    Dir.mktmpdir("routes") do |dir|
      file = File.join(dir, "routes.axum.rb")
      File.write(file, src)
      yield file
    end
  end

  # The emitted Rust must spell each shim the way the catalog does: characters and not bytes for
  # length, Ruby's seven-character strip set and not Rust's trim, and so on. Cheap, so it also runs
  # in the fast gate (test-ruby) without AXUM_CARGO.
  def test_the_emitted_body_spells_the_catalog_templates
    with_source(source(4567)) do |file|
      _out, err, status = Open3.capture3(RbConfig.ruby, EXE, "check", file)
      assert status.success?, err
      main = AxumDsl::Emit.files(AxumDsl.read(file), file)["src/main.rs"]
      assert_includes main, "chars().count() as i64", "String#length must count characters, not bytes"
      assert_includes main, "trim_matches(", "String#strip must strip Ruby's set, not Rust's Unicode trim"
      assert_includes main, "chars().rev().collect::<String>()", "String#reverse must reverse by character"
      assert_includes main, "str_to_i(", "String#to_i must use the pasted catalog helper"
    end
  end

  def test_the_catalog_examples_agree_with_the_running_service
    skip "set AXUM_CARGO=1 to build and drive the generated service (make test-ruby-rust)" unless ENV["AXUM_CARGO"]

    port = free_port
    with_source(source(port)) do |file|
      out = File.join(File.dirname(file), "out")
      _o, err, status = Open3.capture3(RbConfig.ruby, EXE, "build", file, "-o", out)
      assert status.success?, "the emitted crate did not build:\n#{err}"

      bin = binary(out)
      assert File.executable?(bin), "no #{NAME} binary at #{bin}"

      with_server(port, bin, File.join(File.dirname(file), "server.log")) do
        CASES.each do |name, route, input|
          entry = CATALOG.find { |e| e["name"] == name }
          refute_nil entry, "spec/shims/string.yml has no entry #{name}"
          example = entry["examples"].find { |e| e["in"]["s"] == input }
          refute_nil example, "#{name} has no example with s=#{input.inspect}; the differential case is stale"

          ruby = input.public_send(entry["method"]).to_s
          assert_equal example["out"].to_s, ruby,
                       "#{name}: the catalog literal and Ruby disagree, so the literal is not an authority"
          got = get(port, route, input)
          assert_equal ruby.b, got.b, "#{name}: the service answered #{got.inspect}; Ruby answered #{ruby.inspect}"
        end
      end
    end
  end

  private

  # A port nothing holds, so the service binds without a collision.
  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1]
  ensure
    server&.close
  end

  # Prefer the shared target dir the Makefile exports, falling back to the crate's own.
  def binary(out)
    [ENV["CARGO_TARGET_DIR"] && File.join(ENV["CARGO_TARGET_DIR"], "debug", NAME),
     File.join(out, "target", "debug", NAME)].compact.find { |c| File.executable?(c) } ||
      File.join(out, "target", "debug", NAME)
  end

  # GET `path?s=<percent-encoded input>` and return the body, failing on any status but 200.
  def get(port, path, s)
    query = URI.encode_www_form_component(s)
    res = Net::HTTP.start("127.0.0.1", port, open_timeout: 5, read_timeout: 10) do |http|
      http.get("#{path}?s=#{query}")
    end
    assert_equal "200", res.code, "GET #{path}?s=#{query} -> HTTP #{res.code}: #{res.body}"
    res.body.to_s
  end

  # Start the service, wait for its port, yield, and always stop it.
  def with_server(port, bin, log)
    pid = Process.spawn(bin, out: log, err: log, pgroup: true)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
    loop do
      begin
        TCPSocket.new("127.0.0.1", port).close
        break
      rescue SystemCallError, IOError
        flunk "the service exited before it accepted a connection on port #{port}:\n#{File.read(log)}" unless alive?(pid)
        flunk "port #{port} did not accept a connection within 20 s:\n#{File.read(log)}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.05
      end
    end
    yield
  ensure
    if pid
      begin
        Process.kill("TERM", -pid)
      rescue Errno::ESRCH, Errno::EPERM
        begin
          Process.kill("TERM", pid)
        rescue Errno::ESRCH
          nil
        end
      end
      begin
        Process.wait(pid)
      rescue Errno::ECHILD
        nil
      end
    end
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end
end
