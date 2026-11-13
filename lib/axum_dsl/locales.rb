# frozen_string_literal: true

require "yaml"

module AxumDsl
  # Rails-style locales (i18n), read when the compiler runs. A file `config/locales/en.yml` (or the folder
  # `set :locales, "dir"` names) holds one top-level key per locale and nested keys below it, as Rails' do:
  # `en: { bots: { index: { title: "Chat bots" } } }` is the key `bots.index.title`. The files are read with Ruby's
  # YAML and every `t("key")` a body or a view writes becomes a call of a generated Rust function holding a `match`
  # over the request's locale, so the crate has no YAML parser, no lookup table at run time and no new dependency.
  #
  # Locales are opt-in: nothing here runs, and nothing is emitted, unless a body or a view calls `t`. A key the
  # default locale lacks is a compile error (naming the `t` call); a key another locale lacks falls back to the
  # default locale's text. `%{name}` is interpolated as Rails does, and the arguments of the call must be exactly
  # the names the text uses. See docs/views.md and the `t` entry of Docs.
  module Locales
    # Where the files are when `set :locales` names no other folder, relative to the DSL file's folder.
    DIR = "config/locales"
    LOCALE = /\A[a-z]{2,3}(?:-[A-Za-z0-9]+)?\z/
    PLACEHOLDER = /%\{([a-z_][a-z0-9_]*)\}/

    # `texts`: locale => { "a.b.c" => text }. `origin`: [locale, key] => the file the text came from.
    # `sources`: locale => the files that hold it.
    Table = Struct.new(:default, :texts, :origin, :sources, :files, keyword_init: true) do
      def locales = texts.keys.sort

      # The keys the default locale has and `locale` lacks: what `locale` answers with the default text.
      def missing(locale) = texts.fetch(default).keys - texts.fetch(locale).keys
    end

    module_function

    def files(folder, dir) = Dir.glob(File.join(folder, dir, "*.yml")).sort

    # Read every file of the folder into a Table, or call `bad` with why not. `declared` is `default_locale`'s
    # value, or nil: then the default is :en when it is there, else the only locale there is.
    def load(folder, dir, declared, bad:)
      paths = files(folder, dir)
      if paths.empty?
        bad.call("`t` needs locale files, and there are none in #{dir}/ beside the DSL file: add #{dir}/en.yml with " \
                 "`en:` at its top and the key below it, such as `en:\\n  greeting: \"Hello\"` (`set :locales, \"folder\"` names another folder)")
      end
      texts = {}
      origin = {}
      sources = Hash.new { |h, k| h[k] = [] }
      paths.each do |path|
        rel = "#{dir}/#{File.basename(path)}"
        data = begin
          YAML.safe_load_file(path)
        rescue Psych::Exception => e
          bad.call("#{rel}: not valid YAML: #{e.message}")
        end
        next if data.nil?

        bad.call("#{rel}: the top level holds one key per locale (`en:`), got #{data.class}") unless data.is_a?(Hash)
        data.each do |locale, tree|
          locale = locale.to_s
          bad.call("#{rel}: `#{locale}` is not a locale name (`en`, `es`, `pt-BR`)") unless locale.match?(LOCALE)
          bad.call("#{rel}: locale `#{locale}` holds nested keys, got #{tree.class}") unless tree.is_a?(Hash)
          sources[locale] << rel unless sources[locale].include?(rel)
          flatten(tree, [], texts[locale] ||= {}, locale, origin, rel, bad)
        end
      end
      bad.call("#{dir}/ holds no locale") if texts.empty?
      default = (declared || (texts.key?("en") ? "en" : (texts.size == 1 ? texts.keys.first : nil)))&.to_s
      if default.nil?
        bad.call("#{dir}/ holds #{texts.keys.sort.join(', ')} and none is the default: write `default_locale :#{texts.keys.min}` at the top of the file")
      end
      unless texts.key?(default)
        bad.call("`default_locale :#{default}` names a locale no file in #{dir}/ holds (it holds: #{texts.keys.sort.join(', ')})")
      end
      Table.new(default: default, texts: texts, origin: origin, sources: sources.transform_values(&:dup),
                files: paths.map { |p| File.expand_path(p) })
    end

    def flatten(tree, path, out, locale, origin, rel, bad)
      tree.each do |k, v|
        here = path + [k.to_s]
        key = here.join(".")
        case v
        when Hash then flatten(v, here, out, locale, origin, rel, bad)
        when String
          out[key] = v
          origin[[locale, key]] = rel
        else bad.call("#{rel}: `#{locale}.#{key}` is #{v.class}; a translation is a string (arrays, numbers and booleans are not read)")
        end
      end
    end

    # The names a text interpolates (`%{name}`), in order of first use.
    def placeholders(text) = text.scan(PLACEHOLDER).flatten.uniq

    # A text as ["lit", string] and ["arg", name] pieces.
    def pieces(text)
      text.split(/(%\{[a-z_][a-z0-9_]*\})/).reject(&:empty?).map do |part|
        m = part.match(/\A%\{(.*)\}\z/)
        m ? ["arg", m[1]] : ["lit", part]
      end
    end

    # The IR of a file that calls `t`: one function per key used, numbered in order of first use.
    def ir(table, used)
      fns = used.map do |key, u|
        arms = (table.locales - [table.default]).filter_map do |locale|
          text = table.texts[locale][key]
          [locale, pieces(text)] if text
        end
        { "key" => key, "index" => u["index"], "params" => u["params"], "default" => pieces(table.texts[table.default][key]), "arms" => arms.to_h }
      end
      { "default" => table.default, "locales" => table.locales, "fns" => fns.sort_by { |f| f["index"] } }
    end

    # The Rust of the locale picker and one function per key.
    def items(ir)
      i18n = ir["i18n"] or return []
      out = ["// locales (config/locales): the request's `locale` query parameter when it names one, else the default: written by the compiler",
             "fn axum_dsl_locale(query: Option<&str>) -> &'static str {",
             "    for pair in query.unwrap_or(\"\").split('&') {",
             "        if let Some(value) = pair.strip_prefix(\"locale=\") {",
             "            match value {",
             *i18n["locales"].map { |l| "                #{AxumDsl.rstr(l)} => return #{AxumDsl.rstr(l)}," },
             "                _ => {}",
             "            }",
             "        }",
             "    }",
             "    #{AxumDsl.rstr(i18n['default'])}",
             "}",
             ""]
      i18n["fns"].each do |f|
        sig = (["__locale: &str"] + f["params"].map { |p| "p_#{p}: &str" }).join(", ")
        out << "// t(#{f['key'].inspect}): the text of each locale, the default's when a locale has none"
        out << "fn axum_dsl_t_#{f['index']}(#{sig}) -> String {"
        out << "    match __locale {"
        f["arms"].each { |locale, pieces| out << "        #{AxumDsl.rstr(locale)} => #{expr(pieces)}," }
        out << "        _ => #{expr(f['default'])},"
        out << "    }"
        out << "}"
        out << ""
      end
      out
    end

    def expr(pieces)
      return "#{AxumDsl.rstr(pieces.map(&:last).join)}.to_string()" if pieces.all? { |k, _| k == "lit" }

      "[#{pieces.map { |k, v| k == 'lit' ? AxumDsl.rstr(v) : "p_#{v}" }.join(', ')}].concat()"
    end
  end
end
