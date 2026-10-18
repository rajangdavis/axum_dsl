# frozen_string_literal: true

module AxumDsl
  # What a build wrote into its output directory, recorded beside the crate so the next build into the
  # same directory can remove what it no longer emits: the old name of a fingerprinted `static` asset, a
  # file whose `static` or `serve_file` was deleted. One relative path per line, sorted, in NAME.
  #
  # Only a path the previous manifest listed is ever removed, so a file the user put in the output
  # directory survives. An entry that is absolute, climbs out with "..", carries a NUL, or names the
  # manifest itself is ignored, so a hand-edited manifest can delete nothing outside its directory.
  module Manifest
    NAME = ".axum_dsl-files"

    module_function

    # Remove the files under `out` the previous build recorded and `kept` does not name. Returns the
    # relative paths pruned. A first build has no manifest, so it removes nothing.
    def prune(out, kept)
      out = File.expand_path(out)
      paths = paths_for(out, kept)
      pruned = read(out) - paths
      pruned.each do |rel|
        path = File.join(out, rel)
        # A directory is left alone (an empty one is harmless), and so is an entry that vanished since
        # the manifest was read.
        next unless File.symlink?(path) || File.file?(path)

        File.delete(path)
      end
      pruned
    end

    # Record `kept` as the files this build emitted, one per line.
    def record(out, kept)
      write(File.expand_path(out), paths_for(out, kept))
    end

    # `kept` as clean relative paths, sorted and unique.
    def paths_for(out, kept)
      kept.filter_map { |rel| clean(rel, out) }.uniq.sort
    end

    # The paths a previous build recorded under `out`, with every unusable entry dropped.
    def read(out)
      path = File.join(out, NAME)
      return [] unless File.file?(path)

      File.read(path, encoding: "UTF-8").scrub.each_line.filter_map { |line| clean(line.chomp, out) }.uniq
    end

    # `rel` as a path under `out`, or nil when it is not one.
    def clean(rel, out)
      return nil if rel.empty? || rel.include?("\0")
      return nil if File.absolute_path?(rel)
      return nil if rel.split("/").include?("..")

      prefix = out.end_with?(File::SEPARATOR) ? out : out + File::SEPARATOR
      full = File.expand_path(rel, out)
      return nil unless full.start_with?(prefix)
      return nil if full == File.join(out, NAME)

      full.delete_prefix(prefix)
    end

    # Record `paths`, one per line; an unchanged manifest keeps its mtime, like an unchanged crate file.
    def write(out, paths)
      path = File.join(out, NAME)
      text = paths.map { |rel| "#{rel}\n" }.join
      return if File.file?(path) && File.read(path, encoding: "UTF-8").scrub == text

      File.write(path, text)
    end
  end
end
