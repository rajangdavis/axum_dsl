# frozen_string_literal: true

require "fileutils"
require "open3"

module AxumDsl
  # The vetted dependency set: one Cargo.lock that resolves every crate and feature the emitter can declare (the
  # dialect's `make vet-lock` makes it). A generated crate starts from a copy of it and cargo drops what this crate
  # does not use, keeping every locked version; a package the vetted set lacks is refused. cargo then runs with
  # --locked, so a build uses exactly the versions this compiler was tested and audited with.
  module Lockfile
    KEYS = %w[name version source checksum dependencies].freeze

    module_function

    # Pins the crate in `dir` to `vetted`. Needs cargo; nothing is fetched while the vetted set covers the crate.
    def pin(dir, vetted)
      lock = File.join(dir, "Cargo.lock")
      FileUtils.cp(vetted, lock)
      _, err, st = Open3.capture3("cargo", "metadata", "--format-version", "1", "--manifest-path", File.join(dir, "Cargo.toml"))
      raise CompileError, "cargo metadata failed in #{dir}:\n#{err}" unless st.success?

      extra = outside(File.read(lock), File.read(vetted))
      return if extra.empty?

      raise CompileError, "#{lock} needs #{extra.join(', ')}, which the vetted set (#{vetted}) does not have; rerun make vet-lock"
    end

    # The registry packages in `lock` that are not in `vetted` (same name, version, source and checksum), as
    # "name version". The crate itself and other path packages have no source and are not counted.
    def outside(lock, vetted)
      id = ->(p) { p.values_at("name", "version", "source", "checksum") }
      have = parse(vetted).map(&id)
      parse(lock).select { |p| p["source"] && !have.include?(id.call(p)) }.map { |p| "#{p['name']} #{p['version']}" }
    end

    # The packages of a Cargo.lock: each its keys as strings, `dependencies` a list of labels ("name",
    # "name version" or "name version (source)").
    def parse(text)
      text.split(/^\[\[package\]\]\n/).drop(1).map do |b|
        pkg = { "dependencies" => [] }
        b.scan(/^(\w+) = (?:"([^"]*)"|\[\n((?: "[^"]*",\n)*)\])\n/) do |key, str, list|
          raise CompileError, "Cargo.lock: unexpected key #{key}" unless KEYS.include?(key)

          pkg[key] = list ? list.scan(/"([^"]*)"/).flatten : str
        end
        raise CompileError, "Cargo.lock: unreadable package block:\n#{b}" unless b.gsub(/^\s*$\n?/, "").lines.size == expected_lines(pkg)

        pkg
      end
    end

    def expected_lines(pkg) = pkg.size - 1 + (pkg["dependencies"].empty? ? 0 : pkg["dependencies"].size + 2)
  end
end
