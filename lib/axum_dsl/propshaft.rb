# frozen_string_literal: true

require "digest"
require "pathname"

module AxumDsl
  # The names and bodies a `static ..., digest: true` mount serves, the way Propshaft 1.x computes them
  # (propshaft/asset.rb, propshaft/compiler/css_asset_urls.rb):
  #   digest   the first 8 hex digits of SHA-1 over the file's own bytes, then the bytes of every file its CSS
  #            refers to through `url(...)` (including `@import url(...)`), depth first and once each, then the
  #            assets version (`config.assets.version`, "1.0" by default). The bytes hashed are the files', not
  #            the rewritten body, so a referenced file's own references add to its digest only through its bytes
  #            and its place in the walk.
  #   body     a CSS file's `url(name)` becomes `url("<prefix>/<digested name><?#fragment>")` when `name` is a file
  #            of the mount, relative to the CSS file's folder (`../` and a leading `/` as Propshaft reads them);
  #            a reference to anything else (`data:`, `http`, `//`, `#`, a file the mount does not have) is
  #            left as written.
  # Checked against Rails' own names: _reset-9c3efd7b.css (no references), lexxy-2876c58e.css (two @imports, one
  # shared), avatars-279376ab.css and composer-e490638a.css (images the CSS names).
  module Propshaft
    VERSION = "1.0"
    URL = /url\(\s*["']?(?!(?:\#|%23|data|http|\/\/))([^"'\s?#)]+)([#?][^"')]+)?\s*["']?\)/

    module_function

    def css?(rel) = File.extname(rel) == ".css"

    # `name` as written in the CSS file `rel`, as a path inside the mount.
    def resolve(rel, name)
      dir = File.dirname(rel)
      if name.start_with?("../") then Pathname.new("#{dir}/#{name}").cleanpath.to_s
      elsif name.start_with?("/") then name.delete_prefix("/")
      else Pathname.new(dir).join(name).to_s
      end
    end

    # The files of the mount that CSS file `rel` refers to, in the order the references appear.
    def references(rel, text, texts)
      return [] unless css?(rel)

      text.b.scan(URL).filter_map { |name, _| resolve(rel, name.dup.force_encoding(Encoding::UTF_8)) }.select { |path| texts.key?(path) }
    end

    # The 8-digit digest of `rel`; `texts` maps every path of the mount to its bytes.
    def digest(rel, texts, version = VERSION)
      order = []
      walk = lambda do |path|
        next if order.include?(path)

        order << path
        references(path, texts[path], texts).each(&walk)
      end
      walk.call(rel)
      Digest::SHA1.hexdigest(order.map { |path| texts[path].b }.join + version.b)[0, 8]
    end

    # The body served for `rel`: CSS gets its references rewritten to the names in `fingers` (path => digested path)
    # under `prefix` ("/assets", or "" for a mount at "/").
    def compile(rel, text, fingers, prefix)
      return text unless css?(rel)

      text.b.gsub(URL) do
        found = Regexp.last_match
        finger = fingers[resolve(rel, found[1].dup.force_encoding(Encoding::UTF_8))]
        finger ? %[url("#{prefix}/#{finger}#{found[2]}")] : found[0]
      end
    end
  end
end
