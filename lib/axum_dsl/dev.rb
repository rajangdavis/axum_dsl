# frozen_string_literal: true

module AxumDsl
  # `axum_dsl dev`: build and start the service, then poll the mtimes of every file the compiler read and, on a
  # change, re-read, re-emit and rebuild; only a build that succeeded replaces the running server.
  module Dev
    POLL = 0.3

    module_function

    # `emit` is called with the IR and writes the crate. Returns the exit status.
    def run(file, out:, release:, emit:, io: $stderr)
      Session.new(file, out, release, emit, io).run
    end

    class Session
      def initialize(file, out, release, emit, io)
        @file = file
        @out = out
        @release = release
        @emit = emit
        @io = io
        @watch = [file]
        @snap = stamps
        @child = nil
        @stop = false
      end

      def run
        %w[INT TERM].each { |sig| trap(sig) { @stop = true } }
        start if rebuild
        until @stop
          sleep POLL
          reap
          now = stamps
          next if now == @snap

          t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          next unless rebuild && !@stop

          stop_child
          start
          @io.puts "axum_dsl dev: restarted (#{((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000).round} ms build)"
        end
        stop_child
        0
      end

      private

      def stamps
        @watch.to_h do |f|
          st = File.stat(f)
          [f, [st.mtime, st.size]]
        rescue SystemCallError
          [f, nil]
        end
      end

      # Read, emit, build. False (after printing why) leaves the running server alone. The stamps are taken right
      # after the read, so an edit made during the build is seen on the next poll.
      def rebuild
        @snap = stamps
        ir = AxumDsl.read(@file)
        @watch = (ir["inputs"].uniq + [@file]).uniq
        @snap = stamps
        AxumDsl::Notify.report
        @emit.call(ir)
        AxumDsl::CargoBuild.run(@out, release: @release, io: @io) || (@io.puts("axum_dsl dev: build failed; keeping the running server"); false)
      rescue AxumDsl::CompileError => e
        @io.puts e.message
        false
      rescue SystemCallError => e
        @io.puts "axum_dsl: #{e.message}"
        false
      end

      def binary
        name = File.read(File.join(@out, "Cargo.toml"))[/^\[package\].*?^name\s*=\s*"([^"]+)"/m, 1]
        profile = @release ? "release" : "debug"
        target = ENV["CARGO_TARGET_DIR"]
        dirs = [File.join(@out, "target")]
        dirs.unshift(File.expand_path(target, @out)) if target && !target.empty?
        dirs.map { |d| File.expand_path(File.join(d, profile, name), Dir.pwd) }.find { |p| File.executable?(p) }
      end

      def start
        bin = binary
        return @io.puts("axum_dsl dev: no built binary found under #{@out}/target") unless bin

        @child = Process.spawn(bin, chdir: @out)
      end

      def reap
        return unless @child && Process.wait(@child, Process::WNOHANG)

        @io.puts "axum_dsl dev: the server exited (#{$?}); waiting for a change"
        @child = nil
      rescue Errno::ECHILD
        @child = nil
      end

      def stop_child
        return unless @child

        Process.kill("TERM", @child)
        Process.wait(@child)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      ensure
        @child = nil
      end
    end
  end
end
