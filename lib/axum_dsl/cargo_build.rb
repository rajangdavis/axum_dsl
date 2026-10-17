# frozen_string_literal: true

require "json"
require "open3"

module AxumDsl
  # cargo build, with rustc's diagnostics in the generated src/main.rs translated to the DSL
  # line that produced them. Emit writes the line ranges next to Cargo.toml (MAP).
  # Granularity is one DSL declaration (a tool, a params block, a subprocess); code the
  # compiler wrote on its own, and injected Rust files, keep rustc's own location.
  module CargoBuild
    MAP = "axum_dsl.map.json"

    module_function

    # Returns true when cargo succeeds. Diagnostics go to `io`; cargo's own progress lines
    # (Compiling, Finished) are cargo's stderr and pass through untouched.
    def run(out, release: false, io: $stderr)
      map = load_map(out)
      argv = ["cargo", "build", "--message-format=json", *("--release" if release)]
      io.puts "axum_dsl: #{argv.join(' ')} (in #{out})"
      status = nil
      Open3.popen2(*argv, chdir: out) do |_stdin, stdout, wait|
        stdout.each_line { |line| report(line, map, io) }
        status = wait.value
      end
      status.success?
    rescue Errno::ENOENT
      raise CompileError, "axum_dsl: cargo not found on PATH"
    end

    def load_map(out)
      path = File.join(out, MAP)
      File.exist?(path) ? JSON.parse(File.read(path)) : { "source" => nil, "ranges" => [] }
    end

    # One line of cargo's JSON stream. Only compiler messages are shown.
    def report(line, map, io)
      msg = JSON.parse(line)
      return unless msg["reason"] == "compiler-message"

      m = msg["message"]
      span = Array(m["spans"]).find { |s| s["is_primary"] }
      hit = span && span["file_name"] == "src/main.rs" && locate(map, span["line_start"])
      if hit
        io.puts "#{hit['dsl_file'] || map['source']}:#{hit['dsl_line']}: #{m['level']}: #{m['message']} " \
                "(in #{hit['what']}; generated src/main.rs:#{span['line_start']})#{move_hint(m)}"
      end
      io.puts m["rendered"] if m["rendered"]
    rescue JSON::ParserError
      io.puts line
    end

    # A moved-value error (rustc E0382) is move semantics the DSL makes easy to hit: `x || default`
    # moves x, so reading x again on another path fails. Name the fix, since rustc's own help is
    # buried in the rendered text below.
    def move_hint(m)
      return "" unless m.dig("code", "code") == "E0382"

      "; a value is moved on one path and read on another: make both branches yield the same non-nil value, or clone it before the move"
    end

    def locate(map, line) = map["ranges"].find { |r| r["from"] <= line && line <= r["to"] }
  end
end
