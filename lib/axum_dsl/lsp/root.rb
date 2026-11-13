# frozen_string_literal: true

module AxumDsl
  module Lsp
    # Finds the root a fragment is built from. A project is many files and one of them, the root, names the
    # others (`use_dsl "controllers/rooms.axum.rb"`); the compiler only builds from the root, so an editor that
    # opens a fragment has to find it. Nothing here knows the dialect: it is told how to glob candidate files,
    # how to read the files a text includes, and whether a text may be a root on its own.
    #
    # The walk goes from the fragment's directory up to the filesystem root. In each directory, the candidates
    # (the files matching `glob`, but not the fragment itself, and only those `root?` accepts) are tried in name
    # order; the first whose includes, followed through other files, reach the fragment is the root. Files are
    # read through Sources, so an open buffer stands in for its file, and a file that is not there is skipped.
    #
    # The answer is kept per fragment. A kept root is checked again on every ask (its includes are read, which is
    # cheap) and searched for again when it no longer reaches the fragment. "No root" is kept until `forget`,
    # which the server calls when the document is opened, so a keystroke does not walk the directories.
    class Root
      # glob: matched against each directory's entries. includes: text -> the relative paths it includes.
      # root?: text -> may this file be built on its own (a fragment may not).
      def initialize(glob:, includes:, root:)
        @glob = glob
        @includes = includes
        @root = root
        @kept = {}
      end

      # The canonical path of the root that includes `path`, or nil when nothing does.
      def find(path)
        key = AxumDsl.canon(path)
        if @kept.key?(key)
          kept = @kept[key]
          return kept if kept.nil? || reaches?(kept, key)
        end
        @kept[key] = search(key)
      end

      def forget(path) = @kept.delete(AxumDsl.canon(path))

      private

      def search(target)
        dir = File.dirname(target)
        loop do
          Dir.glob(@glob, base: dir).sort.each do |name|
            candidate = AxumDsl.canon(File.join(dir, name))
            next if candidate == target

            text = read(candidate)
            return candidate if text && @root.call(text) && reaches?(candidate, target)
          end
          parent = File.dirname(dir)
          return nil if parent == dir

          dir = parent
        end
      end

      # Does `from` include `target`, directly or through the files it includes? Relative paths resolve against
      # the folder of the file that names them.
      def reaches?(from, target)
        seen = {}
        queue = [from]
        until queue.empty?
          file = queue.shift
          next if seen[file]

          seen[file] = true
          text = read(file) or next
          @includes.call(text).each do |rel|
            full = AxumDsl.canon(File.expand_path(rel, File.dirname(file)))
            return true if full == target

            queue << full
          end
        end
        false
      end

      def read(path)
        Sources[path] || (File.file?(path) ? File.read(path, encoding: "UTF-8") : nil)
      rescue SystemCallError
        nil
      end
    end
  end
end
